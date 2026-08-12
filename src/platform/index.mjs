// Picks the platform layer once. Linux lands here when a linux.mjs exists;
// until then the installer refuses on Linux, so this can only be reached on
// the two supported platforms.
import * as darwin from './darwin.mjs';
import * as win32 from './win32.mjs';

export const platform = process.platform === 'win32' ? win32 : darwin;
