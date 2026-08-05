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

    assert document
           |> LazyHTML.query(
             "meta[property='og:image'][content$='/images/worldloom-social-preview.png']"
           )
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("meta[name='twitter:card'][content='summary_large_image']")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("meta[name='theme-color'][content='#07110f']")
           |> Enum.count() == 1

    assert document |> LazyHTML.query("a[href*='WORLDLOOM_PUBLIC_URL']") |> Enum.empty?()
  end
end
