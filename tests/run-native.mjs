// Cross-platform native Lua suite runner; never use the user's Aseprite profile.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const executable=process.argv[2] ?? process.env.ASEPRITE_EXE;
if (!executable) {
  console.error('Usage: npm run test:native -- /absolute/path/to/aseprite (or set ASEPRITE_EXE)');
  process.exitCode=1;
} else {
  const profile=mkdtempSync(path.join(os.tmpdir(),'aseprite-chat-test-profile-'));
  const suites=['protocol','export','executor','chat','controller','launcher','timeline','account','mcp'];
  if(process.platform!=='win32') suites.push('linux');
  try {
    for(const suite of suites) {
      let output;
      try {
        output=execFileSync(executable,['--batch','--script',path.join(root,`tests/${suite}.lua`)],{
          cwd:root,env:{...process.env,ASEPRITE_USER_FOLDER:profile},encoding:'utf8',timeout:120000,maxBuffer:16*1024*1024
        });
      } catch(error) {
        process.stdout.write(error.stdout ?? ''); process.stderr.write(error.stderr ?? '');
        throw Error(`${suite}: native process failed`,{cause:error});
      }
      process.stdout.write(output);
      // Aseprite can return zero after a Lua assertion; the final pass marker is mandatory.
      const marker=output.match(new RegExp(`^${suite}: (\\d+)(?:/(\\d+))? (?:tests )?passed`, 'm'));
      if(!marker || (marker[2] && marker[1]!==marker[2])) throw Error(`${suite}: missing or incomplete pass marker`);
    }
  } catch(error) {
    console.error(error.message); process.exitCode=1;
  } finally { rmSync(profile,{recursive:true,force:true}); }
}
