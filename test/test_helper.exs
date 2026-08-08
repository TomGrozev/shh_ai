:io.setopts(:standard_io, encoding: :unicode)

ExUnit.start(
  exclude: [:performance, :stress, :redis, :integration, :slow],
  max_cases: System.schedulers_online()
)
