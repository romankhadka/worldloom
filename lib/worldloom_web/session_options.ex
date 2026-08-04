defmodule WorldloomWeb.SessionOptions do
  @base_options [
    store: :cookie,
    key: "_worldloom_key",
    signing_salt: "b+StPlzn",
    http_only: true,
    same_site: "Lax"
  ]

  @spec build(boolean()) :: keyword()
  def build(secure_cookies) when is_boolean(secure_cookies) do
    Keyword.put(@base_options, :secure, secure_cookies)
  end
end
