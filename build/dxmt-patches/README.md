# Madeira's DXMT patches

Changes to DXMT (the `dxmt` submodule) that live in this repository until
they are in DXMT's own repository. `apply.sh` applies them, in file-name
order, to the `dxmt` working tree before `build/dxmt-ios/build.sh` (the
native Direct3D 9 frontend in `libdxmt_combined.a`),
`build/wine-i386/build.sh` (the 32-bit DLLs) and
`build/windows-runtime/build.sh` (the 64-bit DLLs) build DXMT; it skips a
patch that is already applied, and `apply.sh --revert` takes them out. The
`dxmt` submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-d3d9-index-range-per-draw.patch` | A 32-bit Direct3D 9 indexed draw copies only the index bytes it reads, instead of the whole index buffer before every draw after a lock (Call of Duty: Black Ops drew at 2 to 20 FPS). `env.MADEIRA_D3D9_INDEX_RANGE = 0` goes back to the whole copy. Checked by `tests/host/check-d3d9-index-range.py` |
| `0002-d3d11-nv12-textures.patch` | Opt-in (`env.MADEIRA_D3D11_NV12 = 1`): Direct3D 11 NV12 video textures: stored as one buffer-backed R8 texture of Height × 3/2 rows (luma, then interleaved chroma); R8 views read the luma plane and R8G8 views the chroma plane, and copies/Map move both planes. Media Foundation's sample allocator needs it (KINGDOM HEARTS Dream Drop Distance's opening movie was black). A SHARED NV12 texture also gets a process-local handle that madeira-d3d12's OpenSharedHandle opens through `d3d11.dll!MadeiraD3D11SharedTextureInfo` (the same Metal buffer, luma and chroma planes) |
| `0003-ps-nan-guard.patch` | Opt-in (`env.DXMT_PS_NAN_GUARD = 1`): a float render-target output has NaN replaced by 0 and ±Inf by ±65504 before it is written. One such texel in an HDR buffer is spread by bloom/lens-flare blurs into a growing white disc (KINGDOM HEARTS III). Its shaders get their own cache file |
| `0004-precise-math.patch` | Opt-in (`env.DXMT_PRECISE_MATH = 1`): shaders use Metal's precise math functions (rsqrt, log2, pow, ...) and no fast-math flags. The fast variants leave edge cases undefined (log2(0), pow(0, y)) where D3D11 defines them; a NaN from one is the suspected source of KINGDOM HEARTS III's bloom discs and dark blocks. Its shaders get their own cache file |
| `0005-nan-tag-finder.patch` | Diagnostic (`env.DXMT_NAN_TAG = 1`..`4`): a NaN/Inf render-target pixel is painted a bright colour taken from 3 bits of its pixel shader's DXBC checksum (the digit picks which 3), and every pixel shader compiled logs `[nan-tag] shader XXXXXXXX colour NAME`. A screenshot names the shader that makes the NaN. Its shaders get their own cache file |
| `0006-dxbc-dump.patch` | Diagnostic (`env.DXMT_DUMP_SHADER = id,id`): writes the DXBC of the named shaders (ids as `[nan-tag]` prints them) into the log as base64 (`[dxbc-dump]` lines), so a shader found on a device can be read. Uses its own shader cache file, so the shaders are compiled again |

A patch must apply on the current `dxmt` pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
