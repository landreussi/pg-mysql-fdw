# mysql_fdw is not packaged in nixpkgs. Called through
# `postgresql.pkgs.callPackage` so it is built against the same server.
{
  fetchFromGitHub,
  lib,
  mysql,
  postgresql,
  postgresqlBuildExtension,
}:

postgresqlBuildExtension (finalAttrs: {
  pname = "mysql_fdw";
  version = "2.9.3";

  src = fetchFromGitHub {
    owner = "EnterpriseDB";
    repo = "mysql_fdw";
    tag = "REL-${lib.replaceStrings [ "." ] [ "_" ] finalAttrs.version}";
    hash = "sha256-x7iVMc3kXosz6ZefyeinGxojPGxygSok1U48J0r3G5w=";
  };

  # `mysql_config` provides the headers.
  nativeBuildInputs = [ mysql ];

  # The client library is not linked: mysql_fdw dlopen()s it by bare soname
  # at CREATE EXTENSION time, which would only work if it happened to be on
  # the server's library path. Bake the absolute store path in instead.
  postPatch = ''
    substituteInPlace Makefile \
      --replace-fail '_MYSQL_LIBNAME=\"lib$(MYSQL_LIB)$(DLSUFFIX)\"' \
                     '_MYSQL_LIBNAME=\"${lib.getLib mysql}/lib/lib$(MYSQL_LIB)$(DLSUFFIX)\"'
  '';

  makeFlags = [ "USE_PGXS=1" ];

  meta = {
    description = "PostgreSQL foreign data wrapper for MySQL";
    homepage = "https://github.com/EnterpriseDB/mysql_fdw";
    platforms = postgresql.meta.platforms;
    license = lib.licenses.postgresql;
  };
})
