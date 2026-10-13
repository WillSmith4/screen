# Natywne wideo i wybór renderera

Ustawienia → Video → Rendering Mode zawierają dokładnie dwa tryby: **Standard** (domyślny) i **Metal (Experimental)**. Ustawienie jest globalne, zachowuje się po ponownym uruchomieniu i obowiązuje od następnego połączenia ze sprzętowym dekodowaniem. Wyłączenie sprzętowego dekodowania pozostawia dotychczasową ścieżkę FFmpeg/SDL.

Bezpośrednie dekodowanie sprzętowe H.264/HEVC jest aktywne od iOS/iPadOS 17 (w tym 17.5.1). Na starszych obsługiwanych systemach pozostaje wcześniejszy dekoder FFmpeg/VideoToolbox; minimum aplikacji nadal wynosi iOS 15. Te systemy nie mają nowych kluczy API wymagających sprzętowego dekodera.

## Przepływ obrazu

```mermaid
flowchart LR
  Android[Android MediaCodec] --> ADB[Pakiety scrcpy / ADB]
  ADB --> Native[Annex-B i CoreMedia]
  Native --> VT[VideoToolbox: H.264 / HEVC]
  VT --> Surface[CVPixelBuffer / IOSurface]
  Surface --> Presenter[ScrcpyFramePresenter]
  Clock[CADisplayLink do 120 Hz] --> Presenter
  Setting[Rendering Mode] --> Presenter
  Presenter --> Queue[Standard: FIFO VoidLink]
  Queue --> Standard[AVSampleBufferDisplayLayer]
  Presenter --> MetalQueue[Metal: FIFO i worker budzony przez klatki]
  MetalQueue --> Metal[CVMetalTextureCache i CAMetalLayer]
```

W ramach jednej sesji tworzony jest tylko wybrany renderer. Nie ma detekcji HDR, tone mappingu, EDR ani przełączania AVSB/Metal według metadanych koloru. Metal obsługuje SDR NV12 i P010 (10 bitów samo w sobie nie oznacza HDR), zakres pełny/wideo i macierze BT.601/709.

## Co pochodzi z analizy VoidLink

Źródła referencyjne sprawdzono lokalnie w `C:\Users\Admin\Documents\VoidLink-previously-moonlight-zwm\VoidLink`:

| Mechanizm | VoidLink | Nasza implementacja |
|---|---|---|
| Wybór backendu | `Stream/VideoDecoderRenderer.m`, `Base.lproj/iPad.storyboard`, `SettingsSwiftUI.swift` | Te same dwa rodzaje rendererów i nazwy opcji; Standard domyślny. |
| H.264/HEVC | `Stream/VideoDecoderRenderer.m` | Parametry SPS/PPS/VPS, zamiana Annex-B na NAL z długością, CoreMedia → natywne VideoToolbox. |
| Współdzielone bufory GPU | `Metal/MetalVideoRenderer.m` | IOSurface → CVMetalTextureCache → tekstury Y/UV; bez odczytu i przesyłania pikseli przez CPU. |
| Kolejka Standard | `Utility/FrameQueue.m`, `Stream/VideoDecoderRenderer.m` | FIFO, bufor 0–5 (domyślnie 1), naprzemienne odrzucanie, ochrona IDR, oczekiwanie do terminu prezentacji. Szczegóły i test zgodności: [voidlink-standard-pacing.md](voidlink-standard-pacing.md). |
| Prezentacja Standard | `Stream/VideoDecoderRenderer.m` | Cache formatu i gotowe CMSampleBuffer na producencie; bez własnego timebase; output PTS równy targetTimestamp; AVSB bez dodatkowego odrzucania według readiness. |
| Planowanie Metal | `Metal/MetalViewController.m`, `Metal/MetalVideoRenderer.m` | FIFO zamiast nadpisywania najnowszej klatki; worker budzony przy nadejściu danych, niezależny od CADisplayLink; oczekiwanie na GPU i `afterMinimumDuration:1/fps`. |
| Priorytet i odświeżanie | `Stream/VideoDecoderRenderer.m`, `Metal/MetalView.m`, `Metal/MetalViewController.m` | Worker user-interactive, CADisplayLink: default mode dla Standard, common modes dla Metal; częstotliwość ograniczona możliwościami ekranu. |
| Kolor SDR i geometria | `Metal/MetalVideoRenderer.m` | Przeliczenie YUV na RGB na GPU, zachowanie proporcji obrazu, czarne pasy. |

To adaptacja architektury do strumienia scrcpy i iPadOS 17.5.1, a nie skopiowanie całego silnika VoidLink. Zachowano własny protokół ADB, geometrię wejścia i Drawing Toolkit. Nie dodano funkcji Sunshine, interpolacji wymagającej iOS 26 ani HDR. Po analizie logów z 13 października Metal korzysta również z `waitUntilCompleted` na swoim workerze oraz minimalnego czasu prezentacji z VoidLink. CADisplayLink utrzymuje żądanie ProMotion i statystyki, lecz nie wyzwala rysowania Metal. Worker zasypia, gdy FIFO jest puste, i jest budzony przez producenta zamiast stałej pętli referencji. Flaga asynchronicznego dekodowania VideoToolbox pozostaje ustawiona jawnie.

## Własność i odzyskiwanie

Pakiety skompresowane zachowują kolejność i zależności klatek. Po utracie sesji dekodera aplikacja czeka na klatkę kluczową i korzysta z istniejącego ogranicznika żądań resetu Androida. Zmiana formatu, tło, rozłączenie i ponowne połączenie opróżniają prace dekodera przed zmianą stanu. Późny wynik dekodowania nie cofa prezentacji do wcześniejszego PTS.

AVFrame pozostaje opakowaniem własności i wymiarów wymaganym przez istniejące sinks scrcpy. Dla natywnego H.264/HEVC nie wykonuje dekodowania ani konwersji pikseli. FFmpeg nadal jest potrzebny dla dźwięku, AV1, dekodowania programowego, struktur pakietów i nagrywania. Nie zmieniono przypiętych wersji zależności, enkodera Androida, bitrate ani rozdzielczości.

W trybie natywnym porting `screen.c` zachowuje obsługę okna, zdarzeń i geometrii, ale pomija tworzenie tekstury SDL, clear, draw i present/flush. Poprzednio pomijane były tylko przesyłanie YUV i present; clear/draw/flush nadal wykonywały dodatkową pracę GPU na niewidocznej powierzchni SDL.

Nowy renderer wymaga bezpośredniego linkowania systemowego `Metal.framework` w aplikacji. Kontrola zgodności dopuszcza dokładnie ten dodatkowy framework Apple i nadal sprawdza pozostałe biblioteki, ich wersje oraz komplet zasobów. Nie jest to nowa biblioteka zewnętrzna ani aktualizacja FFmpeg/SDL.

## Walidacja

- `test_annexb.c`: prefiksy 3/4 bajty, granice danych, padding, emulation prevention i puste NAL.
- `test-native-video.sh`: rzeczywiste próbki H.264 i HEVC, zmiany wymiarów, IOSurface, reset, oczekiwanie na IDR, błędne dane i asynchroniczna seria klatek.
- `NativeVideoTests.m`: piksele z rzeczywistego GPU Metal, kolory podstawowe, czerń/biel, zakres pełny/wideo, P010 SDR, proporcje i własność bufora do ukończenia GPU.
- `FrameQueueTests.m`: 60 000 operacji porównanych z niezmienioną metodą kolejki VoidLink, cache formatu, oczekiwanie i ograniczenie fizycznej pojemności.
- `FramePresenterTests.m`: FIFO/prefill, output PTS, callback na main, brak własnego timebase, oczekiwanie, odrzucanie wyników starej sesji, żywy CADisplayLink, własność klatek oraz wyłączność warstw po zmianie Standard → Metal → Standard.
- Ten sam test wymusza zatrzymanie pierwszej pracy Metal i serię trzech kolejnych klatek. Przy zablokowanym głównym wątku worker zachowuje FIFO, nie potrzebuje ticków ekranu, rozróżnia sukces/busy/błąd i wraca po pauzie.
- `test_native_render_sdl.c`: produkcyjne funkcje routingu nie wywołują żadnej dodatkowej operacji SDL GPU w trybie natywnym; pozostałe tryby przekazują argumenty i błędy, również dla obrotu.
- Pozostają testy dotyku, Drawing Toolkit, Androida i porównanie bibliotek/zasobów IPA z v4.6.0.

Testy Maca i symulatora nie mierzą fizycznych 120 FPS ani opóźnienia Xiaomi → iPad. Na iPadzie Pro M2 / iPadOS 17.5.1 należy porównać oba tryby przy identycznym kodeku, rozdzielczości, bitrate i FPS=120, osobno dla H.264 i HEVC. Sprawdzić przewijanie, Pencil, obrót, multitasking, przejście do tła, nagrywanie i reconnect. Log `[NativeVideo]` potwierdza ścieżkę dekodowania; `[FramePacing] renderer=...` potwierdza backend. Nowe liczniki opisano w [fps-log-investigation-2026-10-13.md](fps-log-investigation-2026-10-13.md). `submitted` oznacza klatki przekazane do prezentacji, nie fizyczny pomiar ekranu; stary `--print-fps` mierzy obsługę klatek przez SDL.
