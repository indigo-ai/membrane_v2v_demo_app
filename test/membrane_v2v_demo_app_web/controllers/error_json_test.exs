defmodule MembraneV2vDemoAppWeb.ErrorJSONTest do
  use MembraneV2vDemoAppWeb.ConnCase, async: true

  test "renders 404" do
    assert MembraneV2vDemoAppWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert MembraneV2vDemoAppWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
