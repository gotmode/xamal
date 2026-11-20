# The deploy queue test that runs flock(1) needs it installed (Linux has it,
# macOS does not).
ExUnit.start(exclude: if(System.find_executable("flock"), do: [], else: [:flock]))
