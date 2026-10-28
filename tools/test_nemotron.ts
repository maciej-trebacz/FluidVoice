// Run on macOS with Xcode: bun tools/test_nemotron.ts
// Exercises production Swift/C code against a deterministic native runtime fixture.
import {mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

if (process.platform !== 'darwin') throw new Error('This check requires macOS and the Xcode Swift compiler.');
const root = resolve(import.meta.dir, '..');
const temp = await mkdtemp(join(tmpdir(), 'fluid-nemotron-test-'));
async function run(args: string[]) {
    const process = Bun.spawn(args, {cwd: root, stdout: 'inherit', stderr: 'inherit'});
    if (await process.exited !== 0) throw new Error(`Failed: ${args[0]}`);
}
try {
    const include = join(root, 'Vendor/Nemotron/Sources/CNemotron/include');
    await Bun.write(join(temp, 'module.modulemap'), `module CNemotron { header "${include}/CNemotron.h" export * }`);
    await run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-c', '-I', include,
        'Vendor/Nemotron/Sources/CNemotron/CNemotron.c', '-o', join(temp, 'bridge.o')]);
    await run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
        'Tests/NemotronTestRuntime.c', '-o', join(temp, 'fixture.dylib')]);
    await run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-Xcc', `-fmodule-map-file=${temp}/module.modulemap`,
        'Tests/NemotronProviderStubs.swift', 'Sources/Fluid/Services/NemotronTranscribeProvider.swift',
        'Tests/NemotronEngineChecks.swift', join(temp, 'bridge.o'), '-o', join(temp, 'checks')]);
    await run([join(temp, 'checks'), join(temp, 'fixture.dylib')]);
} finally { await rm(temp, {recursive: true, force: true}); }
