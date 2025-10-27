defmodule MembraneV2vDemoAppWeb.PageController do
  use MembraneV2vDemoAppWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end
end
