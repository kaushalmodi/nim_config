from ospaths import `/`, splitPath
from strutils import `%`
from sequtils import filterIt
from strutils import endsWith

switch("nep1", "on")

let
  root = projectDir() # projectDir() needs nim 0.20.0 (or nim devel as of Tue Oct 16 08:41:09 EDT 2018)
  (_, pkgName) = root.splitPath()
  srcFile = root / "src" / (pkgName & ".nim")

task test, "Run tests via 'nim doc' and runnableExamples and tests in tests dir":
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
    deployHtmlFile = deployDir / "index.html"
    deployIdxFile = deployDir / (pkgName & ".idx")
    deployJsFile = deployDir / "dochack.js"
    genDocCmd = "nim doc --index:on -o:$1 $2" % [deployHtmlFile, srcFile]
    sedCmd = "sed -i 's|" & pkgName & r"\.html|index.html|' " & deployIdxFile
    genTheIndexCmd = "nim buildIndex -o:$1/theindex.html $1" % [deployDir]
    docHackJsSource = "https://nim-lang.github.io/Nim/dochack.js" # devel docs dochack.js
  mkDir(deployDir)
  exec(genDocCmd)
  exec(sedCmd) # Hack: replace pkgName.html with index.html in the .idx file
  exec(genTheIndexCmd) # Generate theindex.html only after fixing the .idx file
  if not fileExists(deployJsFile):
    withDir deployDir:
      exec("curl -LO " & docHackJsSource)
