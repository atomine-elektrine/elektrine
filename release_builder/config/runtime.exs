import Config

Path.expand("../../config/runtime.exs", __DIR__)
|> Code.eval_file()
