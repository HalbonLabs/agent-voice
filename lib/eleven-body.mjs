// Builds the ElevenLabs request body as JSON, escaping the text safely.
// Usage:  node eleven-body.mjs "<text>" "<model_id>"
const [text, model] = process.argv.slice(2);
process.stdout.write(JSON.stringify({
  text,
  model_id: model,
  voice_settings: {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true
  }
}));
