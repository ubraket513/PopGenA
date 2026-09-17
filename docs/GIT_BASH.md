# Git Bash entry points

The application is a native Windows CLI. Git Bash provides an additional shell
entry point; the PowerShell entry point remains available. Run these commands
from the clean project directory, `C:/PopGenA/PopGenA`:

```bash
cd /c/PopGenA/PopGenA
./make.sh help
./make.sh
./make.sh check
./popgen --help
./popgen doctor
./popgen run --config config/workflow-demo.json
```

`make.sh` calls the same project-local native Make and Makefile as `make.ps1`.
Make runs from the project root, including when the script is called from another
directory. Relative Make variables such as `CONFIG=config/workflow-demo.json`
are therefore relative to that root. The Makefile still uses Windows commands;
some targets invoke PowerShell internally.

`popgen` runs `build/popgen.exe` and preserves the caller's working directory.
Relative CLI input, output and config paths are relative to the caller's directory.
Quote paths containing spaces or shell characters:

```bash
/c/PopGenA/PopGenA/popgen stats \
  --input '/c/my data/cohort.vcf' \
  --out '/c/my data/results'
```

Both wrappers forward arguments without evaluating them as shell commands and
return the underlying program's exit status. They do not change the global PATH.
Git Bash's normal conversion of `/c/...` arguments to Windows paths remains
enabled. Windows-style `C:/...` paths also work. See the
[MSYS2 path conversion documentation](https://www.msys2.org/docs/filesystem-paths/).

For an initial dependency bootstrap, run the existing explicit download step:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/bootstrap.ps1
```

Dependencies are then local to the project. Ordinary builds and tests use the
existing offline build process. Use Git for Windows' Bash, rather than the
Windows `bash.exe` launcher for WSL.

The extensionless `popgen` launcher has a future Linux dispatch to `build/popgen`.
The Linux implementation and build have not been provided or validated yet;
`make.sh` reports this limitation on Linux instead of running the Windows Makefile.
