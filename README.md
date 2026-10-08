# Windows Sandbox Repair Project

Run `bin\Fix-WindowsSandbox.cmd` to repair and launch Windows Sandbox.

Safety rule for this host: the normal path does not call online DISM and does
not stop live HCS/container services. Two crash-correlated runs stopped in the
repair log immediately after `dism.exe /Online /Get-FeatureInfo`, followed by
unexpected shutdown events, so online servicing is guarded behind the explicit
`-AllowOnlineServicing` switch.

Useful modes:

- `bin\Fix-WindowsSandbox.cmd`
  Normal future-use mode. It audits the current state, repairs the broken
  Sandbox container layer in-place with backups, re-registers Sandbox, launches
  it, and verifies a real client/HCS VM. It does not reboot.
- `bin\Fix-WindowsSandbox.cmd -PlanOnly -NoLaunch`
  Audits Sandbox binaries, AppX registration, and the Windows Containers cache.
- `bin\Fix-WindowsSandbox.cmd -StageBootRepair -NoLaunch`
  Legacy/manual mode that stages delayed boot moves for incomplete Sandbox
  container cache folders. The normal mode no longer uses this.
- `bin\Fix-WindowsSandbox.cmd -NoRebootPrompt`
  Compatibility switch retained for older command lines; normal mode never
  prompts for reboot.
Current diagnosed failure class: `0x80070002` is caused by an incomplete Windows
Containers cache: one layer is missing its `Files` directory and `BaseImages` is
empty. The no-reboot repair backs those paths up under `backups\`, overlays the
missing layer `Files` tree from the intact sibling layer, and then verifies
Sandbox launch.
