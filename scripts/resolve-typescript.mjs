/**
 * Lets Node resolve this project's extensionless relative imports.
 *
 * `node --test` is how the desktop client's tests run, and Node's ESM resolver requires a
 * file extension where TypeScript, Vite and electron-vite all accept none. The rest of the
 * repository writes `./subscription`, and matching that convention matters more than
 * avoiding a dozen lines of loader: introducing `.ts` specifiers into two files to satisfy a
 * test runner would make those two files the odd ones out and leave the next person
 * wondering which style is correct.
 *
 * So the resolution is node-style at the test boundary and extensionless everywhere else.
 * The fallback applies ONLY when normal resolution has already failed, so it cannot mask a
 * genuine missing module - it can only turn "no such file" into "no such file, tried .ts
 * too", and the original error is what is rethrown.
 *
 * Exported as `resolveSync` because `module.registerHooks` is synchronous and the async
 * `resolve` export is consumed by the deprecated `module.register` path.
 */
import { statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const TYPESCRIPT_EXTENSIONS = [".ts", ".tsx", ".mts"];

function isFile(url) {
  try {
    return statSync(fileURLToPath(url)).isFile();
  } catch {
    return false;
  }
}

export function resolveSync(specifier, context, nextResolve) {
  let failure;
  try {
    return nextResolve(specifier, context);
  } catch (error) {
    failure = error;
  }
  // Only relative and absolute specifiers: a bare specifier that failed is a missing
  // dependency, and guessing an extension for it would produce a worse error.
  if (
    failure?.code !== "ERR_MODULE_NOT_FOUND" ||
    !(specifier.startsWith("./") || specifier.startsWith("../") || specifier.startsWith("/"))
  ) {
    throw failure;
  }
  const base = new URL(specifier, context.parentURL);
  for (const extension of TYPESCRIPT_EXTENSIONS) {
    const candidate = pathToFileURL(`${fileURLToPath(base)}${extension}`);
    if (isFile(candidate)) {
      // No `format` is asserted: Node derives it from the extension, and asserting "module"
      // here is what makes it hand a `.ts` file to the plain ESM translator, which has no
      // type stripping and rejects the first `export interface` it meets.
      return { url: candidate.href, shortCircuit: true };
    }
  }
  throw failure;
}

// Kept so the loader also works through the async `module.register` API, which is what older
// Node versions on a contributor's machine may still be using.
export async function resolve(specifier, context, nextResolve) {
  return resolveSync(specifier, context, nextResolve);
}
