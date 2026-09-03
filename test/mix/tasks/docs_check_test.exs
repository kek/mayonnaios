defmodule Mix.Tasks.Docs.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    root = Path.join(System.tmp_dir!(), "docs-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts generated links, anchors, assets, srcsets, and CSS URLs", %{root: root} do
    write(root, "index.html", """
    <!doctype html>
    <html><head>
      <link href="/mayonnaios/assets/site.css?version=1" rel="stylesheet">
      <script src="//cdn.example.invalid/ignored.js"></script>
      <script defer src="docs_config.js"></script>
    </head><body id="top" data-src="not-an-asset.txt">
      <a href="#top">same page</a>
      <a href="guide.html?from=home#cross%20anchor">cross page</a>
      <a href="guide.html#legacy">legacy anchor</a>
      <a href="/mayonnaios/guide.html">Pages-prefixed page</a>
      <a href="manual/">directory index</a>
      <a href="https://example.invalid/no-network">external</a>
      <a href="mailto:docs@example.invalid">mail</a>
      <a href="tel:+15555550100">telephone</a>
      <img src="assets/logo%20mark.svg" srcset="assets/small.png 1x, /mayonnaios/assets/large.png 2x">
      <code><a href="not-a-real-link.html">example attribute</a></code>
      <pre><img src="also-not-real.png"></pre>
    </body></html>
    """)

    write(root, "guide.html", ~s(<h1 id="cross anchor">Guide</h1><a name="legacy"></a>))
    write(root, "manual/index.html", ~s(<a href="../guide.html#cross%20anchor">Guide</a>))

    write(root, "assets/site.css", """
    /* url(ignored-comment.png) */
    body { background: url("paper.png?theme=light#tile") }
    .icon { mask-image: url('/mayonnaios/assets/icon.svg') }
    .remote { background: url(data:image/svg+xml;base64,AAAA) }
    """)

    write(root, "assets/logo mark.svg", "<svg/>")
    write(root, "assets/small.png", "small")
    write(root, "assets/large.png", "large")
    write(root, "assets/paper.png", "paper")
    write(root, "assets/icon.svg", "<svg/>")

    output = run_task(root)

    assert output =~ "Checked 4 generated HTML/CSS files and 12 local references."
  end

  test "supports an output directory relative to the current directory", %{root: root} do
    write(root, "index.html", ~s(<a href="/mayonnaios/">Home</a>))
    parent = Path.dirname(root)
    relative = Path.basename(root)

    output = File.cd!(parent, fn -> run_task(relative) end)

    assert output =~ "Checked 1 generated HTML/CSS files and 1 local references."
  end

  test "reports every missing file, asset, anchor, and escaped path together", %{root: root} do
    write(root, "index.html", """
    <main id="present">
      <a href="missing.html">missing page</a>
      <a href="#absent">missing anchor</a>
      <a href="%2e%2e/outside.html">encoded traversal</a>
      <img src="assets/missing.svg">
      <a href="/other-project/page.html">wrong Pages prefix</a>
    </main>
    """)

    error = assert_raise Mix.Error, fn -> run_task(root) end

    assert error.message =~ "5 invalid local reference(s)"
    assert error.message =~ ~s(index.html: "missing.html")
    assert error.message =~ "local file does not exist"
    assert error.message =~ ~s(index.html: "#absent")
    assert error.message =~ "fragment #absent does not exist"
    assert error.message =~ ~s(index.html: "%2e%2e/outside.html")
    assert error.message =~ "path escapes the documentation output directory"
    assert error.message =~ ~s(index.html: "assets/missing.svg")
    assert error.message =~ ~s(index.html: "/other-project/page.html")
    assert error.message =~ "absolute local path is outside /mayonnaios/"
  end

  test "reports missing srcset and CSS assets with their source files", %{root: root} do
    write(root, "index.html", ~s(<img srcset="ok.png 1x, missing-2x.png 2x">))
    write(root, "ok.png", "ok")
    write(root, "styles/site.css", ".hero { background-image: url(../missing-background.webp); }")

    error = assert_raise Mix.Error, fn -> run_task(root) end

    assert error.message =~ ~s(index.html: "missing-2x.png")
    assert error.message =~ ~s(styles/site.css: "../missing-background.webp")
  end

  test "fails clearly when the output directory is absent", %{root: root} do
    missing = Path.join(root, "not-generated")

    error = assert_raise Mix.Error, fn -> run_task(missing) end

    assert error.message == "documentation output directory does not exist: #{missing}"
  end

  defp run_task(root) do
    Mix.Task.reenable("docs.check")
    capture_io(fn -> Mix.Tasks.Docs.Check.run([root]) end)
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
