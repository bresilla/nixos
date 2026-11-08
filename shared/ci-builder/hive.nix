# What a CI builder needs to know about hive: its end of the cicd0 tunnel, and the
# key the ci container signs in to builders with.
{
  publicKey = "896Ixz1b/zfbokGfM7rM+uFPVBt+/Wte7Oz92xqPLAI=";
  endpoint = "ddns.bresilla.net:51821";
  address = "10.77.0.1";
  # Systems CI builds; a builder emulates the ones it is not.
  systems = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
  ciKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHj9/OLKKJTwBvtYYTUKPzJ3LP77AGUaYctJSJbt69Y3 ci-ci-builder";
}
