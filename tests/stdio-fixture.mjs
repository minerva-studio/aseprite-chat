import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: message.id, result: { received: message, raw: line, pid: process.pid } }) + '\n');
}
