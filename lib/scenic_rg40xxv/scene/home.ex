defmodule ScenicRg40xxv.Scene.Home do
  @moduledoc """
  Proof that Scenic renders on the RG40XXV panel.

  Deliberately uses primitives that would each fail differently: filled rects
  exercise the framebuffer blit, the arc exercises path rasterisation, and the
  text exercises freetype. A blank screen means the driver never attached; a
  screen with shapes but no text means freetype is missing from the system.
  """
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  @width 640
  @height 480

  @graph Graph.build(font: :roboto, font_size: 22)
         |> rect({@width, @height}, fill: {:color, {12, 14, 22}})
         |> text("Scenic on Nerves",
           font_size: 40,
           fill: {:color, {235, 238, 245}},
           translate: {40, 90}
         )
         |> text("Anbernic RG40XXV  ·  Allwinner H700  ·  640x480",
           fill: {:color, {130, 150, 190}},
           translate: {40, 126}
         )
         |> rect({250, 6}, fill: {:color, {90, 170, 255}}, translate: {40, 148})
         |> text("cairo-fb  ->  /dev/fb0",
           font_size: 20,
           fill: {:color, {150, 220, 170}},
           translate: {40, 200}
         )
         # Filled shapes: exercise the rasteriser rather than just blits.
         |> circle(46, fill: {:color, {225, 90, 110}}, translate: {110, 330})
         |> rect({92, 92}, fill: {:color, {245, 190, 80}}, translate: {200, 284})
         |> triangle({{0, 92}, {46, 0}, {92, 92}},
           fill: {:color, {110, 200, 255}},
           translate: {330, 284}
         )
         |> arc({46, 4.2}, stroke: {6, {:color, {180, 140, 255}}}, translate: {510, 330})

  @impl Scenic.Scene
  def init(scene, _param, _opts) do
    {:ok, push_graph(scene, @graph)}
  end
end
