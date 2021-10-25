defmodule Membrane.H264.FFmpeg.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.
  Uses the parser provided by FFmpeg.

  By default, this parser splits the stream into h264 access units,
  each of which is a sequence of NAL units corresponding to one
  video frame, and equips them with the following metadata entries
  under `:h264` key:
  - `key_frame?: boolean` - determines whether the frame is a h264
    I frame.

  Setting custom packetization options affects metadata, see `alignment`
  and `attach_nalus?` options for details.
  """
  use Membrane.Filter
  alias __MODULE__.{NALu, Native}
  alias Membrane.Buffer
  alias Membrane.Caps.Video.H264
  require Membrane.Logger

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any

  def_output_pad :output,
    caps: {H264, stream_format: :byte_stream}

  def_options framerate: [
                type: :framerate,
                spec: H264.framerate_t() | nil,
                default: nil,
                description: """
                Framerate of video stream, see `t:Membrane.Caps.Video.H264.framerate_t/0`
                """
              ],
              sps: [
                type: :binary,
                default: <<>>,
                description: """
                Sequence Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                type: :binary,
                default: <<>>,
                description: """
                Picture Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              alignment: [
                type: :atom,
                spec: :au | :nal,
                default: :au,
                description: """
                Stream units carried by each output buffer. See `t:Membrane.Caps.Video.H264.alignment_t`.

                If alignment is `:nal`, the following metadata entries are added:
                - `type` - h264 nalu type
                - `new_access_unit: access_unit_metadata` - added whenever the new access unit starts.
                  `access_unit_metadata` is the metadata that would be merged into the buffer metadata
                   normally (if `alignment` was `:au`).
                - `end_access_unit: true` - added for each NALu that ends an access unit.
                """
              ],
              attach_nalus?: [
                type: :boolean,
                default: false,
                description: """
                Determines whether to attach NAL units list to the metadata when `alignment` option
                is set to `:au`. For details see `t:Membrane.Caps.Video.H264.nalu_in_metadata_t/0`.
                """
              ],
              skip_until_keyframe?: [
                type: :boolean,
                default: false,
                description: """
                Determines whether to drop the stream until the first key frame is received.
                """
              ]

  @impl true
  def handle_init(opts) do
    state = %{
      parser_ref: nil,
      partial_frame: <<>>,
      first_frame_prefix: opts.sps <> opts.pps,
      framerate: opts.framerate,
      alignment: opts.alignment,
      attach_nalus?: opts.attach_nalus?,
      skip_until_keyframe?: opts.skip_until_keyframe?,
      metadata: nil,
      last_frame_number: 0,
      last_pts: nil,
      last_dts: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    with {:ok, parser_ref} <- Native.create() do
      {:ok, %{state | parser_ref: parser_ref}}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @impl true
  def handle_prepared_to_playing(_ctx, %{skip_until_keyframe: true} = state) do
    {{:ok, event: {:input, %Membrane.KeyframeRequestEvent{}}}, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_process(:input, buffer, ctx, state) do
    payload =
      if ctx.pads.output.start_of_stream? do
        buffer.payload
      else
        state.first_frame_prefix <> buffer.payload
      end

    with {:ok, sizes, output_picture_numbers, resolution_changes} <-
           Native.parse(payload, state.parser_ref) do
      {bufs, state} = parse_access_units(payload, sizes, buffer.metadata, state)

      {bufs, state} =
        add_timestamps_to_buffers(bufs, buffer.pts, buffer.dts, output_picture_numbers, state)

      actions = parse_resolution_changes(state, bufs, resolution_changes)
      {{:ok, actions ++ [redemand: :output]}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp add_timestamps_to_buffers(
         buffers,
         pts,
         dts,
         _output_picture_numbers,
         %{framerate: nil} = state
       ) do
    {Enum.map(buffers, &%{&1 | pts: pts, dts: dts}), %{state | last_pts: pts, last_dts: dts}}
  end

  defp add_timestamps_to_buffers(buffers, _pts, _dts, output_picture_numbers, state) do
    {frames, seconds} = state.framerate

    {buffers, last_frame_number} =
      Enum.zip(buffers, output_picture_numbers)
      |> Enum.map_reduce(state.last_frame_number, fn {buffer, output_frame_number},
                                                     frame_number ->
        pts = div(output_frame_number * Membrane.Time.second() * seconds, frames)
        dts = div(frame_number * Membrane.Time.second() * seconds, frames)
        {%{buffer | pts: pts, dts: dts}, frame_number + 1}
      end)

    {buffers, %{state | last_frame_number: last_frame_number}}
  end

  # analize resolution changes and generate appropriate caps before corresponding buffers
  defp parse_resolution_changes(state, bufs, resolution_changes, acc \\ [], index_offset \\ 0)

  defp parse_resolution_changes(_state, bufs, [], acc, _index_offset) do
    acc ++ [buffer: {:output, bufs}]
  end

  defp parse_resolution_changes(state, bufs, [meta | resolution_changes], acc, index_offset) do
    updated_index = meta.index - index_offset
    {old_bufs, next_bufs} = Enum.split(bufs, updated_index)
    next_caps = mk_caps(state, meta.width, meta.height)

    parse_resolution_changes(
      state,
      next_bufs,
      resolution_changes,
      acc ++ [buffer: {:output, old_bufs}, caps: {:output, next_caps}],
      meta.index
    )
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    # ignoring caps, new ones will be generated in handle_process
    {:ok, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    with {:ok, sizes, output_picture_numbers} <- Native.flush(state.parser_ref) do
      {bufs, state} = parse_access_units(<<>>, sizes, state.metadata, state)

      if state.partial_frame != <<>> do
        Membrane.Logger.warn("Discarding incomplete frame because of end of stream")
      end

      {bufs, state} =
        add_timestamps_to_buffers(
          bufs,
          state.last_pts,
          state.last_dts,
          output_picture_numbers,
          state
        )

      actions = [buffer: {:output, bufs}, end_of_stream: :output]
      {{:ok, actions}, state}
    end
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    {:ok, %{state | parser_ref: nil}}
  end

  defp parse_access_units(input, au_sizes, metadata, %{partial_frame: <<>>} = state) do
    state = %{state | metadata: metadata}
    {buffers, input, state} = do_parse_access_units(input, au_sizes, metadata, state, [])
    {List.flatten(buffers), %{state | partial_frame: input}}
  end

  defp parse_access_units(input, [], _metadata, state) do
    {[], %{state | partial_frame: state.partial_frame <> input}}
  end

  defp parse_access_units(input, [au_size | au_sizes], metadata, state) do
    {first_au_buffers, input, state} =
      do_parse_access_units(state.partial_frame <> input, [au_size], state.metadata, state, [])

    state = %{state | metadata: metadata}

    {buffers, input, state} = do_parse_access_units(input, au_sizes, metadata, state, [])
    {List.flatten(first_au_buffers ++ buffers), %{state | partial_frame: input}}
  end

  defp do_parse_access_units(input, [], _metadata, state, acc) do
    {Enum.reverse(acc), input, state}
  end

  defp do_parse_access_units(input, [au_size | au_sizes], metadata, state, acc) do
    <<au::binary-size(au_size), rest::binary>> = input

    {nalus, au_metadata} = NALu.parse(au)
    au_metadata = Map.merge(metadata, au_metadata)
    state = Map.update!(state, :skip_until_keyframe?, &(&1 and not au_metadata.h264.key_frame?))

    buffers =
      case state do
        %{skip_until_keyframe?: true} ->
          []

        %{alignment: :au, attach_nalus?: true} ->
          [
            %Buffer{
              payload: au,
              metadata: put_in(au_metadata, [:h264, :nalus], nalus)
            }
          ]

        %{alignment: :au, attach_nalus?: false} ->
          [%Buffer{payload: au, metadata: au_metadata}]

        %{alignment: :nal} ->
          Enum.map(nalus, fn nalu ->
            %Buffer{
              payload: :binary.part(au, nalu.prefixed_poslen),
              metadata: Map.merge(metadata, nalu.metadata)
            }
          end)
      end

    do_parse_access_units(rest, au_sizes, metadata, state, [buffers | acc])
  end

  defp mk_caps(state, width, height) do
    {:ok, profile} = Native.get_profile(state.parser_ref)

    %H264{
      width: width,
      height: height,
      framerate: state.framerate || {0, 1},
      alignment: state.alignment,
      nalu_in_metadata?: state.attach_nalus?,
      stream_format: :byte_stream,
      profile: profile
    }
  end
end
