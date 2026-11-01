{ writeTextDir, fake-b }:
(writeTextDir "share/fake-a" "${fake-b}") // { version = "1.0"; }
