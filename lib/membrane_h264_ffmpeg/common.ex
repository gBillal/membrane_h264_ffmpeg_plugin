defmodule Membrane.H264.FFmpeg.Common do
  @h264_time_base 90_000

  # decoder and encoder requires timestamps in h264 time base, that is 1/90_000 [s]
  # timestamps produced by this function are passed to the decoder so
  # they must be integers
  def to_h264_time_base(timestamp) do
    Ratio.mult(timestamp, @h264_time_base) |> Ratio.div(Membrane.Time.second()) |> Ratio.trunc()
  end

  # all timestamps in membrane should be represented in the internal units, that is 1 [ns]
  # this function can return rational number
  def to_membrane_time_base(timestamp) do
    Ratio.mult(timestamp, Membrane.Time.second()) |> Ratio.div(@h264_time_base)
  end
end
