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

    expected_image_alt =
      "A cyan, ember, and olive living weave above Worldloom's gesture dock."

    assert document
           |> LazyHTML.query("meta[property='og:image:alt']")
           |> LazyHTML.attribute("content") == [expected_image_alt]

    assert document
           |> LazyHTML.query("meta[name='twitter:image:alt']")
           |> LazyHTML.attribute("content") == [expected_image_alt]

    assert document
           |> LazyHTML.query("meta[property='og:image:type']")
           |> LazyHTML.attribute("content") == ["image/png"]

    assert document
           |> LazyHTML.query("meta[property='og:image:width']")
           |> LazyHTML.attribute("content") == ["1600"]

    assert document
           |> LazyHTML.query("meta[property='og:image:height']")
           |> LazyHTML.attribute("content") == ["900"]

    assert document
           |> LazyHTML.query("meta[name='twitter:card'][content='summary_large_image']")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("meta[name='theme-color'][content='#120708']")
           |> Enum.count() == 1

    assert document |> LazyHTML.query("link[rel='canonical']") |> Enum.empty?()

    assert document
           |> LazyHTML.query("[href*='WORLDLOOM_PUBLIC_URL'], [content*='WORLDLOOM_PUBLIC_URL']")
           |> Enum.empty?()
  end

  test "serves the social preview as a PNG", %{conn: conn} do
    response = get(conn, "/images/worldloom-social-preview.png")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
    assert byte_size(response.resp_body) > 0
  end

  test "serves copper Worldloom favicon artwork", %{conn: conn} do
    response = get(conn, "/images/logo.svg")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/svg+xml"]
    assert response.resp_body =~ ~s(fill="#E07245")
    refute response.resp_body =~ "#FD4F00"
  end
end
