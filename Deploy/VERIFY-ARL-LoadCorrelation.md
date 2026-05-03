# IntelIMC ARL load-correlation verification

Captured: 2026-05-03 14:35:07+02:00
Buffer size for memcpy: 256 MB (single-threaded)

## Offset 0x0005C

| Phase | Distinct values (raw â†’ b[9:2] â†’ MHz @ BCLK/3) | Distribution |
|---|---|---|
| idle1 | 0x080001D6 â†’ 117 â†’ 3900 MHz: 37/45 (82,2%) | 0x08000118 â†’ 70 â†’ 2333 MHz: 8/45 (17,8%) | n=45 |
| load | 0x080001D6 â†’ 117 â†’ 3900 MHz: 2407/2407 (100%) | n=2407 |
| idle2 | 0x080001D6 â†’ 117 â†’ 3900 MHz: 40/45 (88,9%) | 0x08000118 â†’ 70 â†’ 2333 MHz: 5/45 (11,1%) | n=45 |

## Offset 0x0E448

| Phase | Distinct values (raw â†’ b[9:2] â†’ MHz @ BCLK/3) | Distribution |
|---|---|---|
| idle1 | 0x079F0076 â†’ 29 â†’ 967 MHz: 37/45 (82,2%) | 0x04B00048 â†’ 18 â†’ 600 MHz: 8/45 (17,8%) | n=45 |
| load | 0x079F0076 â†’ 29 â†’ 967 MHz: 2407/2407 (100%) | n=2407 |
| idle2 | 0x079F0076 â†’ 29 â†’ 967 MHz: 40/45 (88,9%) | 0x04B00048 â†’ 18 â†’ 600 MHz: 5/45 (11,1%) | n=45 |

