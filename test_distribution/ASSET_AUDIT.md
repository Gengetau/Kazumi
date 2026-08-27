# Static asset audit

The inventory below was produced before replacement with:

```bash
find assets android/app/src/main/res windows/runner/resources \
  -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
  -o -iname '*.gif' -o -iname '*.ico' -o -iname '*.svg' \)
```

The SHA-256 values are the pre-replacement values from feature source
`9a93916425309c312ed4892fa764fa1ba510e1e4`. Restricted values are also
recorded in `forbidden_asset_hashes.json`; the verifier rejects any occurrence
of one of those bytes in source trees or build archives.

| Path | Pre-replacement SHA-256 | Decision |
| --- | --- | --- |
| `android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png` | `4b8e1407a137591d73cd20f55857b816d50e043d6f07f43a6ba56add5c5c98ce` | Replace: original launcher foreground |
| `android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png` | `0d657d800ebb1e61dd81ae059311b350d1c0873cf1448d4126d9efc56d84cedc` | Replace: original launcher foreground |
| `android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png` | `e78d8ddcbcecc488e7f562af986a25e77d34585f88dfa436d3c6846e3ff47c9e` | Replace: original launcher foreground |
| `android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png` | `cdd37a7325b7fe39203a89a706dd94905f9d4c5d51864fa29ae5b2a30d13a64f` | Replace: original launcher foreground |
| `android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png` | `7d8ba4058aa03f6d674fbb525c382dfa13d00e4bd6fb1ca9251bb1127c34da13` | Replace: original launcher foreground |
| `android/app/src/main/res/drawable/ic_pip_forward_80.png` | `a31408fb148043f11b186b4a6d96b4bcb4c3a238facb9ac9af65c8176867b726` | Retain: simple playback UI icon |
| `android/app/src/main/res/mipmap-hdpi/ic_launcher.png` | `a0b849b2e518f8d72b546115fcfbf608944e19cf9c140b554311d8def95c6c72` | Replace: original launcher icon |
| `android/app/src/main/res/mipmap-mdpi/ic_launcher.png` | `5fc7da240d44302ae453b3b84d0b3cb8a54250e48a0764b76e5788b955244437` | Replace: original launcher icon |
| `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` | `c7e0564728093ba6b399f000f942fcafecbf42e914e49915d742de96a2191a9c` | Replace: original launcher icon |
| `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | `e2dbf0cd15d3ac7ae9f07c6aae3e1344f020674c72684a90f634048a26790a20` | Replace: original launcher icon |
| `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` | `dfd8b45805ada07d5a1421e9eb47f6d29d863737b5ae12cbf47f9af9bd0d57b8` | Replace: original launcher icon |
| `assets/images/danmaku_off.svg` | `b3353290846198cd41a2e3308386d98165348ce0d0581b18d1ab32553eeb7d77` | Retain: simple danmaku UI icon |
| `assets/images/danmaku_setting.svg` | `b6f5b666c6ae6ab254250023316213d4d2df5b88b707652a6c3c933fa196367d` | Retain: simple settings UI icon |
| `assets/images/forward_80.png` | `a31408fb148043f11b186b4a6d96b4bcb4c3a238facb9ac9af65c8176867b726` | Retain: simple playback UI icon |
| `assets/images/loading.png` | `38907a7e7c5ca4e9411c2a6c62447dd215fd131e093839625fb8386c90de2934` | Retain: simple loading UI icon |
| `assets/images/logo/logo_android.png` | `35205669868ac048287ef9e4043c8e081e84734e5a29add54aed8bf6ba7d77b5` | Replace: original Kazumi logo |
| `assets/images/logo/logo_ios.png` | `35205669868ac048287ef9e4043c8e081e84734e5a29add54aed8bf6ba7d77b5` | Replace: original Kazumi logo |
| `assets/images/logo/logo_lanczos.ico` | `a0b849b2e518f8d72b546115fcfbf608944e19cf9c140b554311d8def95c6c72` | Replace: original Kazumi logo |
| `assets/images/logo/logo_linux.png` | `ef2c8e75e6a12f2fd2d399ee59b1fc0293a23f3ac3cf9388e3503e2435f3d125` | Replace: original Kazumi logo |
| `assets/images/logo/logo_rounded.png` | `60ca92b2322a5485203a9b2dfff1f0980f87c073e95bd4379e0e77aaf6ab3acc` | Replace: original Kazumi logo |
| `assets/images/logo/logo_windows.ico` | `55705d76d75351d0039cc4e5f428e0b142a4c9e2485b48ae5d16c7f091b6e90d` | Replace: original Kazumi logo |
| `assets/images/noface.jpeg` | `824be2d5b27ae6c2b8c2b4b63545a187e38ce6cab33bdb56d65b2d04485c03bb` | Replace: source-unclear static avatar |
| `assets/images/playing.gif` | `a9a5e8996dcccdaf6492e901c38701b3ad5b71d4d15f5e1cb148e41b24214761` | Retain: simple playback UI animation |
| `windows/runner/resources/app_icon.ico` | `a0b849b2e518f8d72b546115fcfbf608944e19cf9c140b554311d8def95c6c72` | Replace: original Kazumi logo |

## Visual review decision

The retained PNG/GIF/SVG files are generic playback, loading, and danmaku
controls. The six packaged logo variants, Windows runner icon, all Android
launcher/foreground resources, and `noface.jpeg` were replaced by the
procedural geometry in `branding/`. `static/` screenshots are not copied into
the Android or Windows bundle and are outside this test-package audit.
