class Peek <Formula
  desc "MCP webcam server for macOS"
  homepage "https://github.com/guajardo/peek"
  url "https://github.com/guajardo/peek.git", tag: "v1.0.0"
  version "1.0.0"

  depends_on :macos => :big_sur

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/Peek"
  end
end