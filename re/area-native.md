# Area native — libDataProcessing.so / libSecureKeyBoxJava.so (Q5, Q6)

Legend: **O** observed (REA/Ghidra output or byte read), **D** derived (computed from observations), **I** inferred, **?** unknown.
Evidence IDs are REA `ev_...` (abbreviated to the first 12 hex chars after `ev_`; full IDs in the "Evidence index" at the bottom).
Tags `[sh]` = observed with plain shell tools (`strings`, `nm -D`, `objdump -p`, a small read-only ELF-relocation parser in the scratchpad), NOT REA Evidence.
Tags `[ext]` = external-reference (public web), never observed in the artifact.
Nothing was executed. Static analysis only. Ghidra address = file virtual address + 0x100000 (e.g. `nm` says `JNI_OnLoad`=0x327b10, Ghidra says 0x427b10). All addresses below are Ghidra addresses unless marked "(file VA)".

## 1. Artifacts

| Library | SHA-256 | Size |
| --- | --- | --- |
| `work/native/lib/arm64-v8a/libDataProcessing.so` | `5ebf0458983ed9467a1bee6089b3f508d9dfb483f6b8f37e4033fc7b5d8d6bc7` | 5,486,936 B (REA confirms sha256, ELF arm64, 2432 procedures, 1150 strings; ev_a6aee7a06c3c) |
| `work/native/lib/arm64-v8a/libSecureKeyBoxJava.so` | `6b08bbbc424aef27c73953d8b929d508eb3b98808fd9a2ff31037b32e3ae8f2a` | 4,018,432 B (skimmed with shell tools only, NOT imported into Ghidra) |

Other libs present but out of scope: libsas.so (exports `Java_sas_Loader_l`), libMathRuntimeChecks.so, libsentry*.so [sh].

## 2. JNI symbol map

No `Java_...` exports exist in libDataProcessing.so: `search_procedures "Java_"` is empty (ev_a8587e4177b0). The only JNI exports are `JNI_OnLoad` (0x427b10) and std/cxxabi symbols [sh `nm -D`]. `JNI_OnLoad` is control-flow-flattened and only stores the `JavaVM*` into `DAT_00643490` (ev_8b352d8529b6). The native methods are bound with a **RegisterNatives-style JNINativeMethod table** in `.data.rel.ro` at file VA 0x538258..0x538450 (Ghidra 0x638258..), 21 entries of {name*, signature*, fnptr}. I recovered the table by resolving R_AARCH64_RELATIVE relocations offline [sh]; the function addresses were then confirmed as real procedures in Ghidra (P1/P2/processStream/etc. all decompile/have callees).

| Java native (DataProcessingNative) | JNI signature (from table) | Ghidra fn addr | Notes |
| --- | --- | --- | --- |
| initializeNative | (Ljava/lang/Object;[B)V | 0x42a18c | not in the Java list the lead gave; callees only helper stubs (ev_1a4a1bf6e101) |
| isPatchSupported | (I[BIIILcom/.../ApplicationRegion;[B)Z | 0x42cfa0 | |
| getPatchTimeValues | (I[BLcom/.../...)... | 0x42fab8 | |
| getProductFamily | (I[B[B)I | 0x431ca8 | |
| getActivationCommand | (I[B[B)B | 0x43276c | |
| getActivationPayload | (I[B[BB[B)[B | 0x433410 | callees: 0x40bd2c, 0x40c4e0, auth gate 0x42efc8; no SKB wrapper at depth 1 (ev_b1a78389bf12) |
| getEnableStreamingPayload | (I[B[BBI[B)[B | 0x4351a0 | callees: 0x40cd28, 0x5db53c, 0x6077ac only; no SKB, no auth gate at depth 1 (ev_117c86278c6e) |
| getEncryptedNorthStarPayload | ([B[B[B)[B | 0x43692c | calls SKB wrapper 0x41a5cc (dir flag = encrypt) (ev_dffe774e5192) |
| getDecryptedNorthStarPayload | ([B[B[B)[B | 0x43835c | calls SKB wrapper 0x41a5cc (dir flag = decrypt) (ev_65f492dd9f9f) |
| getStreamingUnlockPayload | (I[B[BBII[B)[B | 0x439a84 | callees 0x40def8, 0x40e644 (family-dispatched, see Q5), auth gate (ev_e098f31861a0) |
| getNeedsReaderInfoForActivation | (I[B)Z | 0x43bb10 | |
| getTotalMemorySize | (I[B)I | 0x43c828 | |
| getNextRegionToRead | (I[B[B[BI[B)L.../MemoryRegion; | 0x43d154 | |
| processScan | (ILcom/.../AlarmConfiguration;...NonActionableConfiguration;GlucoseValueRange;AttenuationConfiguration;[B[BB[BIIIIZ[B[B[BOut x8;[B)DataProcessingResult | 0x43e0b0 | callees include shared pipeline 0x441c00..0x44cdd8 (ev_e2f28e7725f3) |
| processStream | (ILcom/.../AlarmConfiguration;... Z [B[B[B IIII Z I [B[B[B Out x10 [B)DataProcessingResult | 0x44d870 | same shared pipeline (ev_c67dbd8c9586) |
| getStatusCodeNative | (Ljava/lang/String;IIIZ[B)J | 0x44edd8 | |
| activationComplete | ([BII[B[B)[B | 0x450458 | |
| dpSetReaderCodeSimMode | (I[B)V | 0x451778 | |
| dpSetMaxAlgorithmVersion | (I[B)V | 0x452bfc | |
| dpEnableDebugLogging | ([B)V | 0x453ce4 | |
| **P1** | (II[B[B[B)I | **0x4551b4** | Gen2 security step 1; the lead's `gen2Process1`. |
| **P2** | (II[B[B[B)[B | **0x45658c** | Gen2 security step 2; the lead's `gen2Process2`. |

Mapping of `gen2Process1/2(int,int,byte[],byte[])` -> `P1/P2(int,int,byte[],byte[],byte[])`: the native has 3 trailing byte arrays vs 2 in the Java signature the lead quoted; the extra array is the 72-byte caller token (see 4.3). **I** (medium): `Gen2SecurityNativeInterface.gen2Process1/2` are Java wrappers that inject that token and call `DataProcessingNative.P1/P2`. Not verified in Java. Cross-check [ext]: DiaBLE discussion #22 independently says "`P1()` returns an authContext passed to `P2()`" for Gen2 (https://github.com/gui-dos/DiaBLE/discussions/22).

`processStream`/`processScan` ARE the glucose pipeline entry points. There is NO separate `decryptStream` JNI: BLE packet decryption for Gen2 is not a distinct symbol in this table (see Q5).

## 3. Obfuscation profile (important for effort estimates)

- Every function body is control-flow flattened (state-variable switch with opaque predicates and "hash of a table" loops), return values are scrambled constants (`return 0x4bc;` etc.). Ghidra pseudocode is accurate about data flow only locally; do not expect to read algorithms linearly. O: ev_8b352d8529b6, ev_51a7410eaa19, ev_da09cb3e677f.
- Code self-checksum loops and a raw `svc #0` (`CallSupervisor(0)`) in P2 (anti-debug / integrity, **I**). O: ev_51a7410eaa19.
- Copyright string "Abbott Group of Companies ... STRICTLY CONFIDENTIAL" in .data [sh].
- Success code of the embedded SKB engine is the magic `0x312fdf7b` (hardened boolean). O: ev_fecc7a5fbfb4, ev_73f5f838f5bf.

## 4. Q6 — Does the Gen2 / Libre 2 Plus path depend on the whitebox key box?

### VERDICT Q6: **YES — hard portability blocker for the Gen2 (Libre 2 Plus) security path.**
The Gen2 P1/P2 state machine, the NorthStar encrypt/decrypt, and the caller-authorization gate of libDataProcessing all go through an **embedded WhiteCryption Secure Key Box (SKB) engine** that holds the secrets in **wrapped/whitebox key blobs inside libDataProcessing.so itself**. The SKB engine is *statically linked into libDataProcessing.so* — it does not rely on `libSecureKeyBoxJava.so` at runtime for these operations. A macOS app cannot read a Libre 2 Plus over BLE by re-implementing "UID/patchInfo-derived XOR keys" (the pre-Gen2 Libre 2 scheme); the per-session keys are produced from SKB-protected material. Direct BLE reading without either (a) running Abbott's native code as an oracle, or (b) extracting/cryptanalysing the whitebox blobs is **not feasible from static knowledge alone**.

Caveat: for sensor family dispatch, `getEnableStreamingPayload` / `getActivationPayload` show no SKB call at depth 1 (they look like the classic gen1-Libre2 derivations). Whether a *Libre 2 Plus* uses those older paths for anything is **?** (the product-family switch at 0x409d80 is a vtable dispatch that Ghidra did not resolve). Public sources say Gen2 keys are generated per session (below), so the Plus path almost certainly needs P1/P2.

### Evidence for the dependency

| Claim | O/D/I/? | Evidence | Notes |
| --- | --- | --- | --- |
| libDataProcessing.so contains the SKB runtime (same config/property names as the stand-alone libSecureKeyBoxJava.so): "key_cache", "key_cache_max_items", "diversification_guid", "export_guid", "export_key_version", "request_count", "reference_count", "skb_cache_", "sha1", "/proc/%d/cmdline" | O | [sh strings in both libs]; ev_fecc7a5fbfb4 (FUN_004d414c builds the property table) | FUN_004d414c (0x4d414c) = singleton "toolbox/engine" init, returns 0x312fdf7b on success. |
| The SKB engine is initialised from **embedded wrapped-key blobs**. Op 0 of the Gen2 dispatcher (0x4d0b84) imports 2 families x (type 1,2) of blobs from globals `DAT_00641b80[3]`/`DAT_00641b98[3]` via `FUN_004d4710`. Blob pointers (Ghidra): 0x13a964, 0x13aa8e (set A) and 0x13a9f9, 0x13ab23 (set B); each ~149 B, starts with a 4-byte id, `02000000 00000000 10000000` then a fixed 16-byte header `00b041c30135375200851f292323d788` repeated | O | ev_73f5f838f5bf (code), ev_6ccc0de2466b (pointer table bytes), [sh hexdump of 0x3a964/0x3a9f9/0x3aa8e/0x3ab23] | Same 12-byte pattern appears 7x in libDataProcessing and 1x in libSecureKeyBoxJava [sh]. Extra 3 occurrences (0x1ec88, 0x3ade0, 0x3afb3 file VA) are other SKB blobs/tables; not analysed. |
| P1 (JNI `P1`) -> dispatcher `FUN_004d05e4` with opcodes 0, 1, 0x7120, 0x7319, 0x9218; only P1 calls it | O | ev_ee52547a3311 (dispatcher), ev_c1d17a26c35e (sole caller 0x4551b4), ev_4dabc3880514 (P1 callees) | Opcodes are the first `int` argument passed from Java (P1 param_3). |
| op 0x7120: takes a sensor-supplied buffer (len-2) + a hardcoded 16-byte label `ADC_*SpeckPatch#` and asks SKB to create a key via SKB op id `0x6c6a01dc`; returns a session id (counter wraps at 0x7ffffffe, LRU cache of 10 keys) | O/I | ev_2443926d3b1c (FUN_004d0e60), ev_56048cf4e86 (FUN_004d1094), ev_7f4066a97baddd (xref of label 0x123aca -> 0x4d0f2c, 0x4d2188), ev_4f19729354bb (bytes `41 44 43 5f 2a 53 70 65 63 6b 50 61 74 63 68 23`) | O for control flow; "label/KDF context" role is I. Note "Speck" appears only in this ASCII label; the cipher actually applied is performed inside SKB (not visible). Speck cipher use is **?**. |
| op 0x7319: handshake-response handler: input length must be 0x21 (33) when param3==0 else 0x19 (25); verifies a 16-bit checksum over 0x16 bytes (`FUN_004d14bc`), updates session record, then imports a 16-byte item with the 2nd label `ADC_*SpecKpatch#` through SKB (`FUN_004d1094`) and flips a state bit (0x80) | O/I | ev_d5efdb2bdcd7 (FUN_004d1b60), xref of label 0x124772 -> 0x4d1c9c, 0x4d22c4 (ev_2f1b872d4d85) | Interpreted as challenge/response with the sensor. [ext] DiaBLE #22: Gen2 sequence is NFC attributes -> challenge -> session, keys generated per session. |
| op 0x9218 releases a session (`FUN_004d1ff4`) | O/I | ev_ee52547a3311 | matches the [ext] "END_SESSION" naming in DiaBLE notes. |
| NorthStar encrypt and decrypt are the only callers of SKB wrapper `FUN_0041a5cc`; it calls SKB `FUN_004d47c8` (cipher/key op `0x27a47f2`, direction constant `0x4ce337bf` vs `0x651b8bf9` chosen by bit 0 of param_1) | O/I | ev_89da5380370e (0x41a5cc), ev_14a225383636 (callers: 0x43692c, 0x43835c), ev_73bb547734a4 (callers of 0x4d47c8: 0x41a5cc, 0x4d156c, 0x4d2434) | Direction flag mapping decrypt=0x651b8bf9 is O in FUN_004d2434; applied to 0x41a5cc by analogy (I). |
| Caller-authorization gate `FUN_0042efc8` is called by nearly all JNI entries (P1, P2, processScan, processStream, enc/dec NorthStar, getStreamingUnlockPayload, getActivationPayload, activationComplete, getStatusCodeNative) with an extra jbyteArray. It AES-style-decrypts (SKB op `0x6ee8ab36`, direction 0x651b8bf9) a **72-byte token** (`0x48`): bytes 0..7 (each +const) plus an 8-byte constant `0x5c2554241b390141` form a 16-byte IV-ish via FUN_004d23bc; bytes 8..71 (64 B) are decrypted; a ms timestamp is rebuilt from scattered plaintext bytes and compared to `gettimeofday()` with window < 0xBB9 = 3001 ms | O (control flow, constants) / I (semantics) | ev_9b81a66c4bd1 (0x42efc8), ev_8287dee392ca (0x4d0a20), ev_ff3686751b7c (0x4d2434), ev_71198ed7a569 (0x4d0a20 callers = 0x42efc8) | The token is almost certainly produced by the Java side (using the SKB Java binding `libSecureKeyBoxJava.so` / `com.whitecryption.skb`) with the matching whitebox key. This is why the two libs are related. Whether the gate is enforced in the shipping build is **?**: P1/P2 test `DAT_00641b6c` ((1) in .data) against `DAT_00641b68` (2) / `DAT_00641b74` (4) before calling it, and the flattened control flow beyond that was not recovered. |
| Public corroboration that Gen2 cannot be replayed from UID alone | [ext] | DiaBLE discussion #22 (gui-dos, ApApp709, Feb 2026): "keys are generated at each new session", "AES-128GCM is being used for authentication", Gen2 "native code is statically linked", "Juggluco's Android code reuses the native binaries rather than clear-text logic", FRAM XOR-pattern for Gen1 does not match Gen2 | Not observed in our artifact; consistent with it. |
| Juggluco reads Libre 2 Plus by reusing LibreLink's native library (needs LibreLink installed/present as apk) | [ext] | xDrip/Juggluco user reports (search results) | supports "oracle approach is what the community does". |

### What is whitebox here, concretely
- 4 identified SKB data blobs (~149 B each, 16-byte AES-block granularity) + 3 more occurrences of the common header in libDataProcessing.so. Their plaintext key material is **not recoverable by static reading**: SKB is a whitebox (key embedded in obfuscated lookup/cipher-mapped form). **I**: blob format = WhiteCryption SKB wrapped-key object; **? ** exact cipher inside (AES vs other).
- libSecureKeyBoxJava.so is the Java binding for SKB (obfuscated JNI class `lf2f62a667df4091...`, `JNI_RegisterNatives failed`, `SkbJniException`) and does NOT contain the labels `ADC_*SpeckPatch#` / `ADC_*SpecKpatch#` [sh]. It only has 1 hit of the common blob header (0x81473 file VA), i.e. no Abbott blobs of its own beyond the generic engine data. Skimmed only; no deeper analysis.

### Options for the macOS project given the blocker (design notes, not implemented)
1. **Oracle**: run the original `libDataProcessing.so` (and, if the 72-byte token gate is active, the Java side that mints the token incl. `libSecureKeyBoxJava.so`) inside an arm64 Android runtime and feed it NFC/BLE bytes. On Apple silicon a native arm64 Android emulator/device is the practical host; a macOS-native process cannot `dlopen` an Android ELF. This is how Juggluco [ext] is reported to work. Emulation of bionic+JNI under Unicorn/qemu-user is possible but heavy.
2. **Whitebox extraction**: whitebox cryptanalysis (DCA/side-channel style) of the SKB blobs. Research-grade effort; no guarantee.
3. **Cloud/phone relay**: keep the phone (iPhone does NFC) as the Gen2 session-key holder and relay only after session establishment; still needs (1) on a phone.
Not feasible: re-deriving Gen2 keys purely from sensor UID + patchInfo like the old Libre 2 [ext DiaBLE Libre2.swift: 16-bit XOR/shift network keyed by UID + patchInfo bytes 4-5 + unlock count; BLE packet = 46 B, XOR keystream 64 B, CRC16 over first 42 B] — that old scheme is what `getEnableStreamingPayload`/`getStreamingUnlockPayload`-style code likely implements for gen1-style families (**I**), but the same DiaBLE source says Gen2 inherits it without real support (`Libre2Gen2` is an empty subclass).

## 5. Q5 — BLE streaming decrypt + glucose algorithm

### What is established
| Claim | O/D/I/? | Evidence | Notes |
| --- | --- | --- | --- |
| `processStream` (0x44d870) and `processScan` (0x43e0b0) are big wrappers over the same pipeline stages (0x441c00, 0x442d84, 0x443d9c, 0x444688, 0x447228, 0x447b28, 0x448940, 0x4493c4, 0x44a6fc, 0x44afc0, 0x44b9ec, 0x44c348, 0x44cdd8, plus 0x4305d0, 0x4312c0, 0x416fa8/0x41051c/0x410c18); neither calls an SKB wrapper at depth 1 | O | ev_c67dbd8c9586, ev_e2f28e7725f3 | So the glucose math (processStream) is plain code, not whitebox; but their inputs may already be the output of SKB-decrypted data (Gen2) or of the old XOR scheme. |
| processStream takes alarm configuration, glucose range, attenuation config, 3 byte arrays, 4 ints, bool, more arrays and 10 `Out` holders and returns `DataProcessingResult` — i.e. it ingests (already-decrypted?) raw sensor data and returns glucose/trend/alarm values | O (signature from RegisterNatives table) / I (decrypted input) | [sh table]; ev_c67dbd8c9586 | Whether processStream expects ciphertext or plaintext is **?** (needs Java caller analysis; pipeline stages not decompiled). |
| Libre 2/Gen2 BLE decrypt is NOT a separate JNI; the Gen2 session decrypt would be a P1/P2 op (command list in DiaBLE notes [ext]: `GET_SESSION_INFO`, `DECRYPT_BLE_DATA`, `END_SESSION`) | I | ev_ee52547a3311 (only ops 0/1/0x7120/0x7319/0x9218 appear in P1; P2 decompile was truncated by flattening and shows no dispatcher call: ev_51a7410eaa19) | P2 body not recovered: P2's callees list only 0x42efc8 and 0x455c6c (ev_049a7f738260). Likely the actual decrypt/data-return step happens through an indirect/virtual call. **?** |
| `getDecryptedNorthStarPayload([B,[B,[B)[B` decrypts with an SKB cipher (op `0x27a47f2`, direction decrypt); inputs/semantics of the 3 arrays unknown | O (SKB use) / ? (what a "NorthStar payload" is) | ev_65f492dd9f9f, ev_89da5380370e | Not shown to be the BLE glucose packet. Do not assume. |
| Product-family strategy dispatch: `getStreamingUnlockPayload` -> `FUN_0040e644` ends with `FUN_00409d80(key)` returning an object whose slot `+0x58` is called indirectly | O | ev_6f56bcd9fd29 | Implies separate implementation per product family (gen1-Libre2-style vs Gen2); target of the indirect call not resolved. |
| Temperature (or similar) compensation: per record `out[0] = base^(32.5 - rec.temp) * in[0]` where `base = (uint16)(calibration_struct+0x1a) / 1000`; skipped (out=0) when a validity word is 0; stride 20 B out / 10 B in; N records | O (pseudocode) / I (names) | ev_c549fde27bed (FUN_004c3a88) | `DAT_00645170` = per-sensor calibration/context struct. 32.5 reference = suggestive of a skin-temperature reference in C. |
| Warm-up / sensor-age transient term: for t = (param & 0xFFFF) in minutes(?): `f(t) = 80 * ( (1.0013889074325562)^(-t) - (1.0025640726089478)^(-t) )` computed in double, cast to float, then clamped to 8.0 (`if f <= 8.0` branch) and used only when `60 <= t < 5821`; also gated by a bit `(*(DAT_00645170+0x30) & 4)` | O (constants) / D (1.0013889 = 1+1/720 and 1.0025641 = 1+1/390, to 7 digits) / I (meaning) | ev_6ca909baf83d (FUN_004bdc34), ev_3c79475a35ef (pow callers: 0x3f0530, 0x4b3294, 0x4bdc34, 0x4c3a88) | Bi-exponential start-up drift model; unit of t not proven. |
| `log` is imported but never called by any function; `ldexp` only from 0x46bbd4; `pow` from 4 functions | O | ev_3c79475a35ef; callers of log empty (query in session) | Remaining pow callers 0x3f0530 and 0x4b3294 not decompiled. |
| Raw -> mg/dL conversion formula | ? | — | NOT recovered. It lives in the flattened pipeline stages (0x44xxxx) behind `processStream`; each needs separate decompilation + per-sensor calibration struct (`DAT_00645170`) and cannot be derived from strings. |

### What the macOS app would need for Q5 (given what is known)
1. **Session/auth layer** (Gen2): P1/P2 equivalent => needs SKB oracle or extracted keys (see Q6). Without it, no plaintext packets for a Libre 2 Plus.
2. **Packet framing** [ext only, for old Libre 2; unverified for Gen2]: BLE data = 46 bytes; FRAM = 344 bytes; Gen2 keeps the same layouts but with per-session keys (DiaBLE #22).
3. **Algorithm layer**: either call `processStream`/`processScan` via oracle (preferred: it also yields trend, alarms and calibrated mg/dL) or reimplement from recovered stages — requires decompiling ~15 stage functions plus recovering the per-sensor calibration fields (`DAT_00645170 + 0x1a` u16 ratio, `+0x30` flag bits, record layouts of 10 B/20 B). Constants found so far are only fragments (temperature factor base^(32.5-T); bi-exponential warm-up term).
4. Unknown inputs to settle in the Java layer (other workers): what `AlarmConfiguration`/`GlucoseValueRange`/`AttenuationConfiguration` fields feed into the result, and what the three byte[] and 4 ints of `processStream` carry (likely sensor UID, patchInfo, raw packet + timing).

## 6. Findings table (summary)

| # | Claim | Class | Evidence IDs | Notes |
| --- | --- | --- | --- | --- |
| F1 | libDataProcessing has no `Java_` exports; natives are registered via a 21-entry table; P1/P2 are the Gen2 security JNI entry points | O | ev_a8587e4177b0, ev_8b352d8529b6, [sh table] | |
| F2 | SKB whitebox engine is statically embedded in libDataProcessing and holds 4+ wrapped key blobs | O | ev_fecc7a5fbfb4, ev_73f5f838f5bf, ev_6ccc0de2466b | |
| F3 | Gen2 P1 session setup (ops 0x7120/0x7319) imports keys through SKB with labels `ADC_*SpeckPatch#` / `ADC_*SpecKpatch#` | O | ev_2443926d3b1c, ev_d5efdb2bdcd7, ev_56048cf4e864, ev_4f19729354bb | label role I |
| F4 | NorthStar enc/dec use SKB cipher op | O | ev_89da5380370e, ev_14a225383636 | |
| F5 | 72-byte timestamped token authorizes every JNI call (3-second window), verified through SKB | O/I | ev_9b81a66c4bd1, ev_ff3686751b7c, ev_8287dee392ca | enforcement in prod build ? |
| F6 | processStream/processScan are non-SKB algorithm pipelines | O (callees) | ev_c67dbd8c9586, ev_e2f28e7725f3 | depth-1 only |
| F7 | Recovered fragments: temperature factor base^(32.5-T), warm-up bi-exponential (1+1/720, 1+1/390)x80 | O/D/I | ev_c549fde27bed, ev_6ca909baf83d | not mg/dL |
| F8 | Pre-Gen2 Libre 2 scheme is UID/patchInfo/unlock-count XOR network with 46-byte BLE packets | [ext] | DiaBLE Libre2.swift (raw.githubusercontent.com/gui-dos/DiaBLE/main/DiaBLE/Libre2.swift) | external-reference, not observed |
| F9 | Public community state: Gen2 keys per session, not reverse-engineered cleartext; Juggluco reuses Abbott natives | [ext] | github.com/gui-dos/DiaBLE/discussions/22 | external-reference |
| F10 | libSecureKeyBoxJava.so = SKB Java binding (obfuscated JNI classes), lacks Abbott labels | O (shell) | [sh] | skimmed only |

## 7. Open items / not done

- libSecureKeyBoxJava.so not opened in Ghidra (skim-only, as requested; strings/symbols only).
- P2 (0x45658c) real work path not recovered; 0x45914c, 0x409d80 (family dispatch) and the three other pow callers unexplored.
- Whether `getStreamingUnlockPayload`/`getEnableStreamingPayload` are used for Libre 2 Plus at all.
- raw -> mg/dL formula, trend, and the exact BLE packet layout: unresolved.
- Mapping Java `gen2Process1/2` to `P1/P2` needs confirmation from the JADX worker.

## 8. Evidence index (full IDs)

- ev_a6aee7a06c3c38ad2b880f33da5ec54771dcca06e2a5d2f7156f3101d9878d87 binary_overview
- ev_a8587e4177b0a7bdb2907d7b77fdf6a5c073abe2e2c16c23320039619918329e search "Java_" (empty)
- ev_8b352d8529b6109bd4bd30b3b7c4e3b9b330794204738836a9c1c827f1e976f9 JNI_OnLoad
- ev_da09cb3e677fc09bcfaf28180fb0c9f81820de97e02ab117db579bfe67a13164 P1 pseudocode (0x4551b4)
- ev_51a7410eaa199fd248c56b695ac8c3d68f82c4812b317be96b91111d88a3116f P2 pseudocode (0x45658c)
- ev_4dabc3880514cb74beaafe54aa6211057701826df890432ca55b7bd39968bbde P1 callees
- ev_049a7f7382603667c3b2e3b0abb69c80441926b6fc53eb6ce0f2519eab0477a6 P2 callees
- ev_65f492dd9f9fa968fb8584e25a77274327bd5d9ddbe202d0c4a29d939b389569 getDecryptedNorthStarPayload callees
- ev_dffe774e5192c3e8a9ad66f93233003e61a29b0755f8e54dbae1c820b5e96b06 getEncryptedNorthStarPayload callees
- ev_89da5380370eb11aca71807d385baa3aebe807bb71e0c6aa880ae0b54e542c6b FUN_0041a5cc
- ev_14a225383636f6c18fe14dec2209dc1e31995365ca18ffce15c3a50da1ca9325 callers of 0x41a5cc
- ev_73bb547734a47a4ce893b373f8b1209109b4e9504696fac55afe02492d2a9826 callers of 0x4d47c8
- ev_92afc20014eba584ecdecaeb5656692dbf2f1d807e747a9811739d000f6dae07 callers of 0x4d414c
- ev_fecc7a5fbfb44df28904d2f84cf778c0b18e2f1dd449b905217708dab5931161 FUN_004d414c (SKB engine init)
- ev_ee52547a33112542e33af37475d00eb0ae75966db22b7c3c39da6ac402c1f2fb FUN_004d05e4 (Gen2 dispatcher)
- ev_c1d17a26c35e092cb7e61ca8906b32192a7488dcc8784344d87f09d75d59e923 callers of 0x4d05e4
- ev_2443926d3b1c8df4cb1f36fcaaabf53214ddb8a34ed9a8531bd6630acd14f9ec FUN_004d0e60 (op 0x7120)
- ev_56048cf4e86498f77437101f6861dfbd75ca9877b44ab069f1806ad5cb11f07b FUN_004d1094 (SKB key import)
- ev_d5efdb2bdcd7d65eb9341eee1860a50736debc7ea370d0489eb5f44623ac94f3 FUN_004d1b60 (op 0x7319)
- ev_7f4066a97baddd58336f322b129981caae87572c3d1f4e8a68c797cee85a3c23 xrefs ADC_*SpeckPatch#
- ev_2f1b872d4d85b8f691dac3baa5e0c6a6f70df83a5036bfe16b63b0d1def4d9ea xrefs ADC_*SpecKpatch#
- ev_4f19729354bb9ceca05cb17166eaf8457cbf59b8f03b69dbdb2a68b0228f6a0c bytes of ADC_*SpeckPatch#
- ev_73f5f838f5bf80d725e97891f2274c1042ca8edff6c6faa325e14a881119b48c FUN_004d0b84 (SKB blob import / init)
- ev_6ccc0de2466bcda7955b982b41fa641f7c77d8ef354450c1c6c9ed8ca446b986 global pointer table 0x641b60
- ev_9b81a66c4bd13fc0c8ede28fa6f87c0ee44e88e37dc5253ab4442dcd63603087 FUN_0042efc8 (auth gate)
- ev_ff3686751b7c0f82f663ca8bbd72c7710e7e3803c3c4a4045931ad0530c04de9 FUN_004d2434 (token decrypt)
- ev_8287dee392ca24c747a033cb4522f1bb3b49fff48d7f6a84acceff6aa5caa99e FUN_004d0a20
- ev_71198ed7a569799ebde139045e3b1c0cd9a04cda336e43261eedc7051fe80557 callers of 0x4d0a20
- ev_c67dbd8c95863a2d2d776c73e056d4bf9eab4f1d492eab29ced8aea9efcbc4cb processStream callees
- ev_e2f28e7725f3... processScan callees (only the 12-hex prefix was retained in this report; re-run `procedure_callees 0x43e0b0` to get the full ID)
- ev_117c86278c6e97927b557ada50fa141e06003ac2ae62bc12af09089b003ef51c getEnableStreamingPayload callees
- ev_e098f31861a0dd1721119353b739e63085dcad67072773d50b116a8d0e0a4d96 getStreamingUnlockPayload callees
- ev_b1a78389bf12f1f65c25a1526b4397f7e9c3fde69d4c46d308dc1cfd5d644bb3 getActivationPayload callees
- ev_6f56bcd9fd293e3daefee031ff199275c3c5bbcea9bc0ecebfc01313026784d8 FUN_0040e644
- ev_1a4a1bf6e101eb2adc1a621152b6a0003ad7823024f9b073949235134a89b63d initializeNative callees
- ev_3c79475a35efc867117d3387b91111c3a6cc1ad5fc3551065066fc9bab4a5091 callers of pow
- ev_6ca909baf83d8d78e7fd6ae70d2b5ca849271d9137d211aae957e88a1609085f FUN_004bdc34 (warm-up term)
- ev_c549fde27bed1ce554ca015b9059343b19aa643906f0a6cd48c92a2596a1b9c6 FUN_004c3a88 (temp compensation)

External references (not observed): https://github.com/gui-dos/DiaBLE/discussions/22 ; https://raw.githubusercontent.com/gui-dos/DiaBLE/main/DiaBLE/Libre2.swift (fetched and summarised by the WebFetch model; treat as secondhand).
