# AI Subtitle Toolkit

Simple Windows app for extracting embedded English subtitles from video files and translating `.srt` subtitle files with Gemini.

## Download

[Download v1.1.2](https://github.com/Nom1fan/ai-subtitle-toolkit/releases/download/v1.1.2/AiSubtitleToolkit-v1.1.2.zip)

## What It Does

- Extracts embedded English text subtitles from video files to external `.eng.srt` files.
- Uses `ffprobe` to inspect embedded subtitle streams.
- Uses a faster SubRip extraction path for embedded SRT subtitle streams.
- Uses `ffmpeg` to extract supported text subtitle streams.
- Skips unsupported bitmap/image subtitle streams.
- Translates subtitle files from Hebrew to English.
- Can also translate English to Hebrew.
- Keeps SRT timing and numbering intact.
- Preserves common subtitle tags such as `<i>` and `{\\an8}`.
- Saves the translated file next to the original subtitle.

## How To Run

Double-click:

```text
Run AI Subtitle Toolkit.cmd
```

If that does not work, right-click `AiSubtitleToolkit.ps1` and choose **Run with PowerShell**.

## How To Use

1. Click **Browse...** and choose an `.srt` file or a supported video file.
2. For `.srt` files, choose translation direction:
   - **Hebrew to English** is selected by default.
   - **English to Hebrew** is also available.
3. Click **Extract** to extract embedded English subtitles from a selected video.
4. Click **Translate** to translate a selected `.srt`.
5. Wait for the progress bar to finish.

If you choose a video file, the app first extracts an embedded English text subtitle stream to:

```text
video-name.eng.srt
```

When you click **Extract**, the app stops after creating that file. Select the extracted `.eng.srt` afterward and click **Translate** to translate it. The extracted and translated subtitle files are created in the same folder as the source video or subtitle.

Use **Cancel** to stop extraction or translation. The app stops the background process and does not write a completed output file.

Before translating, the app checks a sample of the subtitle text. If the selected direction looks wrong, for example Hebrew to English on an already-English file, it warns you and stops.

Output names:

```text
Extracted English subtitle:  video-name.eng.srt
Hebrew to English:  name.eng.srt
English to Hebrew:  name.heb.srt
```

## ffmpeg / ffprobe

Video subtitle extraction requires `ffmpeg` and `ffprobe`.

The release ZIP includes `ffmpeg.exe` and `ffprobe.exe`. If you run from source, the app looks for them in:

1. The same folder as `AiSubtitleToolkit.ps1`.
2. Your Windows `PATH`.

Supported video extensions:

```text
.mkv, .mp4, .avi, .mov, .m4v, .webm
```

## First Run: Gemini API Key

The first time you translate, the app asks for a Gemini API key.

To get one:

1. Open:

   ```text
   https://aistudio.google.com/app/apikey
   ```

2. Sign in with your Google account.
3. Click **Create API key**.
4. If asked, create or select a Google Cloud project.
5. Copy the key.
6. Paste it into the app and click **Save**.

After that, the app remembers the key and will not ask again.

The key is stored encrypted for your Windows user at:

```text
%APPDATA%\AiSubtitleToolkit\key.bin
```

Use **Reset API Key** if you need to replace it.

## Notes

- The app uses `gemini-3.5-flash`.
- Large subtitles are translated in chunks.
- Release ZIPs include FFmpeg executables from GyanD/codexffmpeg; see `THIRD_PARTY_NOTICES.txt`.
- If Gemini rate limits or quota are hit, try again later.
- Do not share your API key.

## Tests

Run the local tests from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-AiSubtitleToolkit.ps1
```

The tests check script parsing, core subtitle helpers, extraction helpers, shared worker logs, language-direction protection, Gemini response parsing errors, mock worker success, and mock worker cancellation without calling Gemini.

To also run the opt-in live Gemini end-to-end tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-AiSubtitleToolkit.ps1 -Wet
```

The wet tests use the saved API key and make two tiny live Gemini API calls. They translate one Hebrew subtitle to English and one English subtitle to Hebrew, then check the worker status, logs, output file, timing, and detected output language.
