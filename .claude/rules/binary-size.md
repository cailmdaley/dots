# Binary Size Tracking

After rebuilding dots with `zig build -Doptimize=ReleaseSmall`, check the binary size:

```bash
ls -lh zig-out/bin/dot
```

Compare against README.md line 7 and line 275 which state the current size.

If the size differs significantly (±50KB), update:
1. Line 7: `Minimal task tracker... (X.XMB vs 19MB)...`
2. Line 275: `| Binary | 19 MB | X.X MB | NNx smaller |`

Calculate the "Nx smaller" as `19 / size_in_mb` rounded to nearest integer.

Current documented size: 1.2MB
Current actual size: ~910KB (0.9MB) → needs update to "21x smaller"
