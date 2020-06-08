const
  zipSwitches = @["-9", "-T", "-v", "-r"]

  pySetupCfg = """# See: https://setuptools.readthedocs.io/en/latest/setuptools.html#metadata
[metadata]
name             = $1
keywords         = python3, cpython, speed, cython, c, performance, compiled, native, fast, nim
license          = MIT
platforms        = Linux, Darwin, Windows
version          = 0.0.1
license_file     = LICENSE
long_description = file: README.md
long_description_content_type = text/markdown
classifiers =
  Environment :: Other Environment
  Intended Audience :: Other Audience
  Operating System :: OS Independent
  Programming Language :: Python

[options]
zip_safe = True
include_package_data = True
python_requires = >=3.8
packages = find:

[options.package_data]
* = *.c, *.h

[options.exclude_package_data]
* = *.py, *.pyc, *.sh, *.nim, *.so, *.dll, *.zip, *.js, *.tests, *.tests.*, tests.*, tests

[options.packages.find]
include = *.c, *.h
exclude = *.py, *.pyc, *.sh, *.nim, *.so, *.dll, *.zip, *.js, *.tests, *.tests.*, tests.*, tests"""

  pySetupPy = """import os, sys, pathlib, setuptools
if sys.platform.startswith("lin"):
  folder = "lin" # OS is Linux
elif sys.platform.startswith("win"):
  folder = "win" # OS is Windows
else:
  folder = "mac" # OS is Mac (Manual compile and copy of C files required)
sources = []
for c_source_file in os.listdir(folder): # Walk the folder with C files.
  if c_source_file.endswith(".c"):       # Collect all C files.
    sources.append(str(pathlib.Path(folder) / c_source_file))
setuptools.setup(ext_modules = [setuptools.Extension(
  extra_compile_args = ["-flto", "-ffast-math", "-march=native", "-mtune=native", "-O3", "-fsingle-precision-constant"],
  name = "$1", sources = sources, extra_link_args = ["-s"], include_dirs = [folder])])"""

  pyPkgInfo = """Metadata-Version: 2.1
Name: $1
Version: 0.0.1
License: MIT
Keywords: python3, cpython, speed, cython, c, performance, compiled, native, fast, nim
Description: Powered by https://Nim-lang.org
Classifier: Environment :: Other Environment
Classifier: Intended Audience :: Other Audience
Classifier: Operating System :: OS Independent
Classifier: Programming Language :: Python
Classifier: Programming Language :: Python :: Implementation :: CPython
Requires-Python: >=3.8"""

task nim4pypi, "Package Nim+Nimpy Python lib for Linux/Windows/Mac ready for upload to PYPI":
  ## nim4pypi takes 1 full path of 1 Nim+Nimpy source code file and packages it for Pythons PYPI,
  ## creates setup.py, setup.cfg, helper scripts, ZIP Python Package, C files, H files, and more.
  switch("verbosity", "0")
  hint("Processing", false)
  const gccWin32 = system.findExe("x86_64-w64-mingw32-gcc")
  assert gccWin32.len > 0, "x86_64-w64-mingw32-gcc not found"
  const zipExe = system.findExe("zip")
  assert zipExe.len > 0, "zip command not found"
  const nimbaseH = getHomeDir() / ".choosenim/toolchains/nim-" & NimVersion / "lib/nimbase.h"
  let
    (_, binFiles) = parseArgs()
    sourcePath = $binFiles[0] # Just pass full path of main file of the lib, even if lib has several files
    packageName = splitFile(sourcePath).name
  assert sourcePath.len > 0 and packageName.len > 0, "Nim source code file not found"
  --app:lib  # Settings for Python module compilation
  --opt:speed
  --cpu:amd64
  --forceBuild
  --define:ssl
  --threads:on
  --compileOnly
  --define:danger
  --define:release
  --exceptions:goto
  --gc:markAndSweep
  --tlsEmulation:off
  --define:noSignalHandler
  --excessiveStackTrace:off
  --outdir:getTempDir() # Save the *.so to /tmp, so is not on the package, we ship C
  rmDir("dist")
  mkDir("dist")
  writeFile("upload2pypi.sh", "twine upload --verbose --repository-url 'https://test.pypi.org/legacy/' --comment 'Powered by https://Nim-lang.org' dist/*.zip\n")
  writeFile("package4pypi.sh", "cd dist && zip -9 -T -v -r " & packageName & ".zip *\n")
  writeFile("install2local4testing.sh", "sudo pip --verbose install dist/*.zip --no-binary :all:\nsudo pip uninstall " & packageName)
  withDir("dist"):
    mkDir("lin") # C for Linux, compile for Linux, save C files to lin/*.c
    mkDir("win") # C for Windows, compile for Windows, save C files to win/*.c
    mkDir("mac") # C for Mac OSX, manual compile, manual copy C files to mac/*.c
    writeFile("setup.py", pySetupPy.format(packageName))   # C Extension compilation with Python stdlib
    writeFile("setup.cfg", pySetupCfg.format(packageName)) # Metadata
    mkDir(packageName & ".egg-info")
    withDir(packageName & ".egg-info"): # Old and weird metadata format of Python packages
      writeFile("top_level.txt", "")    # Serializes data as empty files(?), because reasons
      writeFile("dependency_links.txt", "")
      writeFile("requires.txt", "")
      writeFile("zip-safe", "")
      writeFile("PKG-INFO", pyPkgInfo.format(packageName)) # This one has the actual data
    withDir("lin"):
      selfExec "compileToC --nimcache:. " & sourcePath   # C for Linux
      rmFile(packageName & ".json") # Nim compiler creates this, unneeded here
      cpFile(nimbaseH, "nimbase.h") # H file must be with the C files
    withDir("win"): # Repeat the same but for Windows
      selfExec "compileToC --nimcache:. --os:windows --gcc.exe:" & gccWin32 & " --gcc.linkerexe:" & gccWin32 & " " & sourcePath
      rmFile(packageName & ".json")
      cpFile(nimbaseH, "nimbase.h")
    withDir("mac"):
      cpFile(nimbaseH, "nimbase.h")
    runUtil(packageName & ".zip *", zipExe, zipSwitches)
    echo "\nApple Mac OSX: Compile manually and copy all the .c files to 'mac/' folder, see https://github.com/foxlet/macOS-Simple-KVM or https://github.com/sickcodes/Docker-OSX"
  setCommand("nop")
