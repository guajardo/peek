class Peek <Formula
  desc "MCP webcam server for macOS"
  homepage "https://github.com/guajardo/peek"
  url "https://github.com/guajardo/peek.git", tag: "v1.0.0"
  version "1.0.0"

  depends_on :macos => :big_sur
  depends_on xcode: ["13.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/Peek"
  end

  test do
    assert_match "Peek", shell_output("#{bin}/Peek --help 2>&1", 0)
  end
end
