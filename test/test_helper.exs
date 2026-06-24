:io.setopts(:standard_io, encoding: :unicode)

ExUnit.start(exclude: [:performance, :stress, :redis])
