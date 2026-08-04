if Mix.env() == :dev do
  Mix.Task.run("worldloom.seed_demo")
end
