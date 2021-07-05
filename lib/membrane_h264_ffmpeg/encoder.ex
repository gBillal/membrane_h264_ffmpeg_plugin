defmodule Membrane.H264.FFmpeg.Encoder do
  @moduledoc """
  Membrane element that encodes raw video frames to H264 format.

  The element expects each frame to be received in a separate buffer, so the parser
  (`Membrane.Element.RawVideo.Parser`) may be required in a pipeline before
  the encoder (e.g. when input is read from `Membrane.File.Source`).

  Additionally, the encoder has to receive proper caps with picture format and dimensions
  before any encoding takes place.

  Please check `t:t/0` for available options.
  """
  use Membrane.Filter
  use Bunch.Typespec
  alias __MODULE__.Native
  alias Membrane.Buffer
  alias Membrane.Caps.Video.{H264, Raw}
  alias Membrane.H264.FFmpeg.Common

  def_input_pad :input,
    demand_unit: :buffers,
    caps: {Raw, format: one_of([:I420, :I422]), aligned: true}

  def_output_pad :output,
    caps: {H264, stream_format: :byte_stream, alignment: :au}

  @default_crf 23

  @list_type presets :: [
               :ultrafast,
               :superfast,
               :veryfast,
               :faster,
               :fast,
               :medium,
               :slow,
               :slower,
               :veryslow,
               :placebo
             ]

  def_options add_dts?: [
                spec: boolean(),
                default: false,
                description: """
                Setting this flag to true causes decoder to add presentation timestamp (dts) taken from buffer timestamp into the AVFrame and in consequence to the produced packet.
                """
              ],
              crf: [
                description: """
                Constant rate factor that affects the quality of output stream.
                Value of 0 is lossless compression while 51 (for 8-bit samples)
                or 63 (10-bit) offers the worst quality.
                The range is exponential, so increasing the CRF value +6 results
                in roughly half the bitrate / file size, while -6 leads
                to roughly twice the bitrate.
                """,
                type: :int,
                default: @default_crf
              ],
              preset: [
                description: """
                Collection of predefined options providing certain encoding.
                The slower the preset choosen, the higher compression for the
                same quality can be achieved.
                """,
                type: :atom,
                spec: presets(),
                default: :medium
              ],
              profile: [
                description: """
                Defines the features that will have to be supported by decoder
                to decode video encoded with this element.
                """,
                type: :atom,
                spec: H264.profile_t(),
                default: :high
              ]

  @impl true
  def handle_init(opts) do
    state = Map.merge(opts, %{encoder_ref: nil})
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, %{encoder_ref: nil} = state) do
    # Wait until we have an encoder
    {:ok, state}
  end

  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{metadata: metadata, payload: payload}, ctx, state) do
    %{encoder_ref: encoder_ref} = state
    pts = metadata[:pts] || 0

    case Native.encode_with_pts(payload, Common.to_h264_time_base(pts), encoder_ref) do
      {:ok, dts_list, frames} ->
        bufs = wrap_frames(dts_list, frames, state.add_dts?)
        in_caps = ctx.pads.input.caps

        caps =
          {:output,
           %H264{
             alignment: :au,
             framerate: in_caps.framerate,
             height: in_caps.height,
             width: in_caps.width,
             profile: state.profile,
             stream_format: :byte_stream
           }}

        # redemand is needed until the internal buffer of encoder is filled (no buffers will be
        # generated before that) but it is a noop if the demand has been fulfilled
        actions = [{:caps, caps} | bufs] ++ [redemand: :output]
        {{:ok, actions}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl true
  def handle_caps(:input, %Raw{} = caps, _ctx, state) do
    {framerate_num, framerate_denom} = caps.framerate

    case Native.create(
           caps.width,
           caps.height,
           caps.format,
           state.preset,
           state.profile,
           framerate_num,
           framerate_denom,
           state.crf
         ) do
      {:ok, encoder_ref} -> {{:ok, redemand: :output}, %{state | encoder_ref: encoder_ref}}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    with {:ok, dts_list, frames} <- Native.flush(state.encoder_ref),
         bufs <- wrap_frames(dts_list, frames, state.add_dts?) do
      actions = bufs ++ [end_of_stream: :output, notify: {:end_of_stream, :input}]
      {{:ok, actions}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    {:ok, %{state | encoder_ref: nil}}
  end

  defp wrap_frames([], [], _add_dts), do: []

  defp wrap_frames(dts_list, frames, true) do
    Enum.zip(dts_list, frames)
    |> Enum.map(fn {dts, frame} ->
      %Buffer{metadata: %{dts: Common.to_membrane_time_base(dts)}, payload: frame}
    end)
    |> then(&[buffer: {:output, &1}])
  end

  defp wrap_frames(_dts_list, frames, false) do
    Enum.map(frames, fn frame ->
      %Buffer{payload: frame}
    end)
    |> then(&[buffer: {:output, &1}])
  end
end
