defmodule WorldloomWeb.PageMetadataTest do
  use WorldloomWeb.ConnCase

  test "publishes complete truthful artwork metadata", %{conn: conn} do
    document =
      conn
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("meta[name='description']") |> Enum.count() == 1

    assert document
           |> LazyHTML.query("meta[property='og:title'][content*='Worldloom']")
           |> Enum.count() == 1

    expected_image_url =
      WorldloomWeb.Endpoint.url() <> "/images/worldloom-social-preview.png"

    for selector <- ["meta[property='og:image']", "meta[name='twitter:image']"] do
      image_metadata = LazyHTML.query(document, selector)
      assert LazyHTML.attribute(image_metadata, "content") == [expected_image_url]

      assert %URI{scheme: scheme, host: host} = URI.parse(expected_image_url)
      assert scheme in ["http", "https"]
      assert is_binary(host) and host != ""
    end

    assert document
           |> LazyHTML.query("meta[name='twitter:card'][content='summary_large_image']")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("meta[name='theme-color'][content='#07110f']")
           |> Enum.count() == 1

    assert document |> LazyHTML.query("link[rel='canonical']") |> Enum.empty?()

    assert document
           |> LazyHTML.query("[href*='WORLDLOOM_PUBLIC_URL'], [content*='WORLDLOOM_PUBLIC_URL']")
           |> Enum.empty?()
  end
end
