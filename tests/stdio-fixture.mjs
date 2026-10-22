import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: message.id, result: { received: message, raw: line, pid: process.pid,
    originator: process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE,
    argv: process.argv.slice(2), codexHome: process.env.CODEX_HOME ?? null,
    apiKey: process.env.ASEPRITE_CHAT_API_KEY ?? null } }) + '\n');
}
