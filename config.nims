from macros import error
from strutils import `%`, endsWith, strip, replace
from sequtils import filterIt, concat
import oswalkdir

when NimMajor < 1 and NimMinor <= 19 and NimPatch < 9:
  from ospaths import `/`, splitPath, splitFile
  when not defined(projectDir):
    let projectDir = getCurrentDir
    echo "\nprojectDir() is not defined, fallback to getCurrentDir(), you must run it from the project directory (needs Nim devel).\n"
else:
  from os import `/`, splitPath, splitFile

when defined(strictMode):
  switch("styleCheck", "error")
else:
  switch("styleCheck", "hint")

## Constants
const
  doOptimize = true
  stripSwitches = @["--strip-all", "--remove-section=.comment"]
  # upxSwitches = @["--best"]     # fast
  upxSwitches = @["--ultra-brute"] # slower
  checksumsSwitches = @["--tag"]
  gpgSignSwitches = @["--clear-sign", "--armor", "--detach-sign", "--digest-algo sha512"]
  gpgEncryptSwitches = @["--armor", "--symmetric", "--s2k-digest-algo sha512", "--cipher-algo AES256", "-z 9"] # 9=Max, 0=Disabled

proc getGitRootMaybe(): string =
  ## Try to get the path to the current git root directory.
  ## Return ``projectDir()`` if a ``.git`` directory is not found.
  const
    maxAttempts = 10            # arbitrarily picked
  var
    path = projectDir() # projectDir() needs nim 0.20.0 (or nim devel as of Tue Oct 16 08:41:09 EDT 2018)
    attempt = 0
  while (attempt < maxAttempts) and (not existsDir(path / ".git")):
    path = path / "../"
    attempt += 1
  if existsDir(path / ".git"):
    result = path
  else:
    result = projectDir()

## Lets
let
  root = getGitRootMaybe()
  (_, pkgName) = root.splitPath()
  srcFile = root / "src" / (pkgName & ".nim")
  # pcre
  pcreVersion = getEnv("PCREVER", "8.42")
  pcreSourceDir = "pcre-" & pcreVersion
  pcreArchiveFile = pcreSourceDir & ".tar.bz2"
  pcreDownloadLink = "https://downloads.sourceforge.net/pcre/" & pcreArchiveFile
  pcreInstallDir = (root / "pcre/") & pcreVersion
  # http://www.linuxfromscratch.org/blfs/view/8.1/general/pcre.html
  pcreConfigureCmd = ["./configure", "--prefix=" & pcreInstallDir, "--enable-pcre16", "--enable-pcre32", "--disable-shared"]
  pcreIncludeDir = pcreInstallDir / "include"
  pcreLibDir = pcreInstallDir / "lib"
  pcreLibFile = pcreLibDir / "libpcre.a"
  # libressl
  libreSslVersion = getEnv("LIBRESSLVER", "2.8.1")
  libreSslSourceDir = "libressl-" & libreSslVersion
  libreSslArchiveFile = libreSslSourceDir & ".tar.gz"
  libreSslDownloadLink = "https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/" & libreSslArchiveFile
  libreSslInstallDir = (root / "libressl/") & libreSslVersion
  libreSslConfigureCmd = ["./configure", "--disable-shared", "--prefix=" & libreSslInstallDir]
  libreSslLibDir = libreSslInstallDir / "lib"
  libreSslLibFile = libreSslLibDir / "libssl.a"
  libreCryptoLibFile = libreSslLibDir / "libcrypto.a"
  libreSslIncludeDir = libreSslInstallDir / "include/openssl"
  # openssl
  openSslSeedConfigOsCompiler = "linux-x86_64"
  openSslVersion = getEnv("OPENSSLVER", "1.1.1")
  openSslSourceDir = "openssl-" & openSslVersion
  openSslArchiveFile = openSslSourceDir & ".tar.gz"
  openSslDownloadLink = "https://www.openssl.org/source/" & openSslArchiveFile
  openSslInstallDir = (root / "openssl/") & openSslVersion
  # "no-async" is needed for openssl to compile using musl
  #   - https://gitter.im/nim-lang/Nim?at=5bbf75c3ae7be940163cc198
  #   - https://www.openwall.com/lists/musl/2016/02/04/5
  # -DOPENSSL_NO_SECURE_MEMORY is needed to make openssl compile using musl.
  #   - https://github.com/openssl/openssl/issues/7207#issuecomment-420814524
  openSslConfigureCmd = ["./Configure", openSslSeedConfigOsCompiler, "no-shared", "no-zlib", "no-async", "-fPIC", "-DOPENSSL_NO_SECURE_MEMORY", "--prefix=" & openSslInstallDir]
  openSslLibDir = openSslInstallDir / "lib"
  openSslLibFile = openSslLibDir / "libssl.a"
  openCryptoLibFile = openSslLibDir / "libcrypto.a"
  openSslIncludeDir = openSslInstallDir / "include/openssl"
  # Custom Header file to force to link to GLibC 2.5, for old Linux (x86_64).
  glibc25DownloadLink = "https://raw.githubusercontent.com/wheybags/glibc_version_header/master/version_headers/x64/force_link_glibc_2.5.h"


## Helper Procs
# https://github.com/kaushalmodi/elnim
proc dollar[T](s: T): string =
  result = $s
proc mapconcat[T](s: openArray[T]; sep = " "; op: proc(x: T): string = dollar): string =
  ## Concatenate elements of ``s`` after applying ``op`` to each element.
  ## Separate each element using ``sep``.
  for i, x in s:
    result.add(op(x))
    if i < s.len-1:
      result.add(sep)

proc parseArgs(): tuple[switches: seq[string], nonSwitches: seq[string]] =
  ## Parse the args and return its components as
  ## ``(switches, nonSwitches)``.
  let
    numParams = paramCount()    # count starts at 0
                                # So "nim musl foo.nim" will have a count of 2.
  # param 0 will always be "nim"
  doAssert numParams >= 1
  # param 1 will always be the task name like "musl".
  let
    subCmd = paramStr(1)

  if numParams < 2:
    error("The '$1' sub-command needs at least one non-switch argument" % [subCmd])

  for i in 2 .. numParams:
    if paramStr(i)[0] == '-':    # -d:foo or --define:foo
      result.switches.add(paramStr(i))
    else:
      result.nonSwitches.add(paramStr(i))

proc runUtil(f, util: string; args: seq[string]) =
  ## Run ``util`` executable with ``args`` on ``f`` file.
  doAssert findExe(util) != "",
     "'$1' executable was not found" % [util]
  let
    cmd = concat(@[util], args, @[f]).mapconcat()
  echo "Running '$1' .." % [cmd]
  exec cmd

template preBuild(targetPlusSwitches: string) =
  assert targetPlusSwitches.len > 0, "Build arguments must not be empty"
  when defined(libressl) and defined(openssl):
    error("Define only 'libressl' or 'openssl', not both.")
  let (switches, nimFiles) = parseArgs()
  assert nimFiles.len > 0, """
    This nim sub-command accepts at least one Nim file name
      Examples: nim <SUB COMMAND> FILE.nim
                nim <SUB COMMAND> FILE1.nim FILE2.nim
                nim <SUB COMMAND> -d:pcre FILE.nim
  """
  var allBuildCmds {.inject.} = newSeqOfCap[tuple[nimArgs, binFile: string]](nimFiles.len)
  for f in nimFiles:
    let
      extraSwitches = switches.mapconcat()
      (dirName, baseName, _) = splitFile(f)
      binFile = dirName / baseName  # Save the binary in the same dir as the nim file
      nimArgsArray = when doOptimize:
                       [targetPlusSwitches, "-d:musl", "-d:release", "--opt:size", "--passL:-s", "--listFullPaths:off", "--excessiveStackTrace:off", extraSwitches, " --out:" & binFile, f]
                     else:
                       [targetPlusSwitches, "-d:musl", extraSwitches, " --out:" & binFile, f]
      nimArgs = nimArgsArray.mapconcat()
    allBuildCmds.add((nimArgs: nimArgs, binFile: binFile))


## Tasks
task installPcre, "Install PCRE using musl-gcc":
  if not existsFile(pcreLibFile):
    if not existsDir(pcreSourceDir):
      if not existsFile(pcreArchiveFile):
        exec("curl -LO " & pcreDownloadLink)
      exec("tar xf " & pcreArchiveFile)
    else:
      echo "PCRE lib source dir " & pcreSourceDir & " already exists"
    withDir pcreSourceDir:
      putEnv("CC", "musl-gcc -static")
      exec(pcreConfigureCmd.mapconcat())
      exec("make -j8")
      exec("make install")
  else:
    echo pcreLibFile & " already exists"
  setCommand("nop")

task installLibreSsl, "Install LIBRESSL using musl-gcc":
  if (not existsFile(libreSslLibFile)) or (not existsFile(libreCryptoLibFile)):
    if not existsDir(libreSslSourceDir):
      if not existsFile(libreSslArchiveFile):
        exec("curl -LO " & libreSslDownloadLink)
      exec("tar xf " & libreSslArchiveFile)
    else:
      echo "LibreSSL lib source dir " & libreSslSourceDir & " already exists"
    withDir libreSslSourceDir:
      #  -idirafter /usr/include/ # Needed for linux/sysctl.h
      #  -idirafter /usr/include/x86_64-linux-gnu/ # Needed for Travis/Ubuntu build to pass, for asm/types.h
      putEnv("CC", "musl-gcc -static -idirafter /usr/include/ -idirafter /usr/include/x86_64-linux-gnu/")
      putEnv("C_INCLUDE_PATH", libreSslIncludeDir)
      exec(libreSslConfigureCmd.mapconcat())
      exec("make -j8 -C crypto") # build just the "crypto" component
      exec("make -j8 -C ssl")    # build just the "ssl" component
      exec("make -C crypto install")
      exec("make -C ssl install")
  else:
    echo libreSslLibFile & " already exists"
  setCommand("nop")

task installOpenSsl, "Install OPENSSL using musl-gcc":
  if (not existsFile(openSslLibFile)) or (not existsFile(openCryptoLibFile)):
    if not existsDir(openSslSourceDir):
      if not existsFile(openSslArchiveFile):
        exec("curl -LO " & openSslDownloadLink)
      exec("tar xf " & openSslArchiveFile)
    else:
      echo "OpenSSL lib source dir " & openSslSourceDir & " already exists"
    withDir openSslSourceDir:
      # https://gcc.gnu.org/onlinedocs/gcc/Directory-Options.html
      #  -idirafter /usr/include/ # Needed for Travis/Ubuntu build to pass, for linux/version.h, etc.
      #  -idirafter /usr/include/x86_64-linux-gnu/ # Needed for Travis/Ubuntu build to pass, for asm/types.h
      putEnv("CC", "musl-gcc -static -idirafter /usr/include/ -idirafter /usr/include/x86_64-linux-gnu/")
      putEnv("C_INCLUDE_PATH", openSslIncludeDir)
      exec(openSslConfigureCmd.mapconcat())
      echo "The insecure switch -DOPENSSL_NO_SECURE_MEMORY is needed so that OpenSSL can be compiled using MUSL."
      exec("make -j8 depend")
      exec("make -j8")
      exec("make install_sw")
  else:
    echo openSslLibFile & " already exists"
  setCommand("nop")

task strip, "Optimize the binary size using 'strip' utility":
  ## Usage: nim strip <FILE1> <FILE2> ..
  let
    (_, binFiles) = parseArgs()
  for f in binFiles:
    f.runUtil("strip", stripSwitches)
  setCommand("nop")

task upx, "Optimize the binary size using 'upx' utility":
  ## Usage: nim upx <FILE1> <FILE2> ..
  let
    (_, binFiles) = parseArgs()
  for f in binFiles:
    f.runUtil("upx", upxSwitches)
  setCommand("nop")

task checksums, "Generate checksums of the binary using 'sha1sum' and 'md5sum'":
  ## Usage: nim checksums <FILE1> <FILE2> ..
  let (_, binFiles) = parseArgs()
  for f in binFiles:
    f.runUtil("md5sum", checksumsSwitches)
    f.runUtil("sha1sum", checksumsSwitches)
  setCommand("nop")

task sign, "Sign the binary using 'gpg' (armored, ascii)":
  ## Usage: nim sign <FILE1> <FILE2> ..
  let (_, binFiles) = parseArgs()
  for f in binFiles:
    f.runUtil("gpg", gpgSignSwitches)
  setCommand("nop")

task encrypt, "Encrypt the binary using 'gpg' (compressed, symmetric, ascii)":
  ## Usage: nim encrypt <FILE1> <FILE2> ..
  # Decrypt is just double click or 'gpg --decrypt' (Asks Password).
  let (_, binFiles) = parseArgs()
  for f in binFiles:
    f.runUtil("gpg", gpgEncryptSwitches)
  setCommand("nop")

task musl, "Build an optimized static binary using musl":
  ## Usage: nim musl [-d:pcre] [-d:libressl|-d:openssl] <FILE1> <FILE2> ..
  preBuild("c")
  for cmd in allBuildCmds:
    # Build binary
    echo "\nRunning 'nim " & cmd.nimArgs & "' .."
    selfExec cmd.nimArgs
    when doOptimize:
      cmd.binFile.runUtil("strip", stripSwitches)
      cmd.binFile.runUtil("upx", upxSwitches)
    echo "Built: " & cmd.binFile

task glibc25, "Build C, dynamically linked to GLibC 2.5 (x86_64)":
  ## Usage: nim glibc25 file.nim
  # See https://github.com/wheybags/glibc_version_header/pull/21.
  let
    header = getCurrentDir() / "force_link_glibc_2.5.h"
    optns = ["-ffast-math", "-flto", "-include" & header] # Don't use -march here
  if not existsFile(header):
    exec("curl -LO " & glibc25DownloadLink)
  var passCSwitches: string
  for o in optns:
    passCSwitches.add(" --passC:" & o)
  preBuild("c -d:ssl" & passCSwitches)
  for cmd in allBuildCmds:
    echo "\nRunning 'nim " & cmd.nimArgs
    # preBuild auto-adds "-d:musl", so remove that.
    # FIXME: Make preBuild not always add that switch. -- Thu Jun 13 12:13:17 EDT 2019 - kmodi
    selfExec cmd.nimArgs.replace("-d:musl", "")
    when doOptimize:
      cmd.binFile.runUtil("strip", stripSwitches)
    # Version check -- Changes from GLIBC_2.15 to GLIBC_2.5
    cmd.binFile.runUtil("ldd", @["-v"])

task js2asm, "Build JS, print Assembly from that JS (performance debug)":
  ## Usage: nim js2asm <FILE1> <FILE2> ..
  # This debugs performance of JavaScript, the less ASM the better JS.
  # This ASM is NOT usable as proper ASM, just for Debug performance.
  preBuild("js")
  for cmd in allBuildCmds:
    echo "\nRunning 'nim " & cmd.nimArgs
    selfExec cmd.nimArgs
    cmd.binFile.runUtil("node", @["--print_code"])

task c2asm, "Build C, print Assembly from that C (performance debug)":
  ## Usage: nim c2asm <FILE1> <FILE2> ..
  # This debugs performance of Nim, the less ASM the better your Nim.
  const
    optns = [ # This cleans up the produced ASM as much as possible.
      "-ffast-math", "-march=native", "-fno-math-errno", "-fno-exceptions",
      "-fno-asynchronous-unwind-tables", "-fno-inline-functions", "-std=c11",
      "-fno-inline-functions-called-once", "-fno-inline-small-functions",
      "-xc", "-s", "-S", "-O3", "-masm=intel", "-o-"]
  var passCSwitches: string
  for o in optns:
    passCSwitches.add(" --passC:" & o)
  preBuild("compileToC --compileOnly:on -d:danger -d:noSignalHandler" & passCSwitches)
  for cmd in allBuildCmds:
    echo "\nRunning 'nim " & cmd.nimArgs
    selfExec cmd.nimArgs
    let cSource = nimcacheDir() / cmd.binFile & ".nim.c"
    cSource.runUtil("gcc", @optns)

task rmfiles, "Recursively remove all files with the specific extension(s) from the current directory":
  ## Usage: nim rmfiles pyc c o
  for extToDelete in parseArgs().nonSwitches:  # Invalid Patterns: "", " ", "\t"
    assert extToDelete.strip.len > 0, "Specified extension must not be whitespace or empty string"
    assert extToDelete[0] != '.', "Do not prefix the extensions with dot"
    for file in walkDirRec(getCurrentDir(), {pcFile, pcDir}):
      if file.splitFile().ext == "." & extToDelete:
        # echo "file to delete: ", file
        rmFile(file)
  setCommand("nop")

task test, "Run tests via 'nim doc' (runnableExamples) and tests in tests/ dir":
  let
    testDir = root / "tests"
  selfExec("doc " & srcFile)
  if dirExists(testDir):
    let
      testFiles = listFiles(testDir).filterIt(it.len >= 5 and it.endsWith(".nim"))
    for t in testFiles:
      selfExec "c -r " & t

task docs, "Deploy doc html + search index to public/ directory":
  let
    deployDir = root / "public"
    docOutBaseName = "index"
    deployHtmlFile = deployDir / (docOutBaseName & ".html")
    genDocCmd = "nim doc --out:$1 --index:on $2" % [deployHtmlFile, srcFile]
    deployIdxFile = deployDir / (pkgName & ".idx")
    genTheIndexCmd = "nim buildIndex -o:$1/theindex.html $1" % [deployDir]
    deployJsFile = deployDir / "dochack.js"
    docHackJsSource = "https://nim-lang.github.io/Nim/dochack.js" # devel docs dochack.js
  mkDir(deployDir)
  exec(genDocCmd)
  exec(genTheIndexCmd)
  if not fileExists(deployJsFile):
    withDir deployDir:
      exec("curl -LO " & docHackJsSource)

# https://www.reddit.com/r/nim/comments/byzq7d/go_run_for_nim/
task runc, "Run equivalent of 'nim c -r ..'":
  switch("run")
  switch("verbosity", "0")
  hint("Processing", false)
  setCommand("c")

task runcpp, "Run equivalent of 'nim cpp -r ..'":
  switch("run")
  switch("verbosity", "0")
  hint("Processing", false)
  setCommand("cpp")

## Define Switch Parsing
# -d:musl
when defined(musl):
  var
    muslGccPath: string
  echo "  [-d:musl] Building a static binary using musl .."
  muslGccPath = findExe("musl-gcc")
  if muslGccPath == "":
    error("'musl-gcc' binary was not found in PATH.")
  switch("passL", "-static")
  switch("gcc.exe", muslGccPath)
  switch("gcc.linkerexe", muslGccPath)
  # -d:pcre
  when defined(pcre):
    if not existsFile(pcreLibFile):
      selfExec "installPcre"    # Install PCRE in current dir if pcreLibFile is not found
    switch("passC", "-I" & pcreIncludeDir) # So that pcre.h is found when running the musl task
    switch("define", "usePcreHeader")
    switch("passL", pcreLibFile)
  # -d:libressl or -d:openssl
  when defined(libressl) or defined(openssl):
    switch("define", "ssl")     # Pass -d:ssl to nim
    when defined(libressl):
      let
        sslLibFile = libreSslLibFile
        cryptoLibFile = libreCryptoLibFile
        sslIncludeDir = libreSslIncludeDir
        sslLibDir = libreSslLibDir
    when defined(openssl):
      let
        sslLibFile = openSslLibFile
        cryptoLibFile = openCryptoLibFile
        sslIncludeDir = openSslIncludeDir
        sslLibDir = openSslLibDir

    if (not existsFile(sslLibFile)) or (not existsFile(cryptoLibFile)):
      # Install SSL in current dir if sslLibFile or cryptoLibFile is not found
      when defined(libressl):
        selfExec "installLibreSsl"
      when defined(openssl):
        selfExec "installOpenSsl"
    switch("passC", "-I" & sslIncludeDir) # So that ssl.h is found when running the musl task
    switch("passL", "-L" & sslLibDir)
    switch("passL", "-lssl")
    switch("passL", "-lcrypto") # This *has* to come *after* -lssl
    switch("dynlibOverride", "libssl")
    switch("dynlibOverride", "libcrypto")
