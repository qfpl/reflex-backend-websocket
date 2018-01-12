{ mkDerivation, base, binary, bytestring, containers, hashable
, lens, mtl, reflex, reflex-basic-host, reflex-binary, stdenv, stm
, these, ttrie, websockets
}:
mkDerivation {
  pname = "reflex-server-websocket";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    base binary bytestring hashable lens mtl reflex reflex-binary stm
    ttrie websockets
  ];
  executableHaskellDepends = [
    base bytestring containers mtl reflex reflex-basic-host stm these
    websockets
  ];
  license = stdenv.lib.licenses.bsd3;
}
