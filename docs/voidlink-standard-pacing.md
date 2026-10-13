# Standard: zgodność z queue buffering VoidLink

Referencja: lokalne źródła VoidLink, commit `2d9558e1`, `Stream/VideoDecoderRenderer.m`, `Utility/FrameQueue.m` i baza `Limelight.xcdatamodeld`. To implementacja queue buffering związana z optymalizacjami standardowego renderera, a nie samo wykorzystanie tych samych API Apple.

## Przeniesione zachowanie

- Standard nie ustawia `controlTimebase` warstwy AVSampleBufferDisplayLayer.
- Zdekodowane obrazy są opakowywane w CMSampleBuffer przed trafieniem do kolejki; CMVideoFormatDescription jest współdzielony, dopóki `CMVideoFormatDescriptionMatchesImageBuffer` potwierdza zgodność.
- FIFO ma pierścień 15 pozycji i high-water mark `max(1, framesToBuffer)`. Zakres ustawienia: 0–5, domyślnie 1. Wartość 0 pomija początkowe wypełnianie.
- Pierwsza prezentacja czeka na wybraną liczbę klatek. Po jej rozpoczęciu pusta kolejka może czekać na obraz do `CADisplayLink.targetTimestamp`, sprawdzając dostępność co 100 µs, jak `dequeueWithTimeoutSync` VoidLink.
- Przy zapełnieniu kolejki odrzucanie jest naprzemienne: najpierw nowa klatka, potem najstarsza niebędąca klatką kluczową. Klatki kluczowe są przyjmowane ponad high-water mark. Flaga klatki kluczowej jest przenoszona z parsera H.264/HEVC przez VideoToolbox do kolejki.
- `Async Frame Dequeue` domyślnie jest włączone, zgodnie z bazą VoidLink. Oczekiwanie wykonuje worker o priorytecie user-interactive, a prezentację callback na main. Po wyłączeniu oczekiwanie odbywa się bezpośrednio w callbacku wyświetlania. Ten tryb może na krótko zajmować główny wątek — to zachowanie referencji.
- Standard używa NSDefaultRunLoopMode; Metal zachowuje NSRunLoopCommonModes. Preferowana częstotliwość pochodzi z ustawień i możliwości ekranu.
- Prezentacja ustawia `CMSampleBufferSetOutputPresentationTimeStamp` na `targetTimestamp`, bez dodawania kolejnego okresu odświeżania i bez zastępowania spóźnionego terminu bieżącym czasem.
- Usunięto poprzednią, dodatkową politykę odrzucania klatek na podstawie `isReadyForMoreMediaData`. Standard przekazuje próbkę do AVSB jak VoidLink; awaria warstwy powoduje flush i żądanie klatki kluczowej przez istniejący ogranicznik scrcpy.

Ustawienia: **Settings → Video → Rendering Mode → Standard**, **Frames to Buffer**, **Async Frame Dequeue**. Zmiany stosują się po ponownym połączeniu. Metal pozostaje osobną opcją Experimental.

## Granice zgodności

Zgodność dotyczy opisanej polityki Standard i decyzji kolejkowania w zakresie fizycznej pojemności bufora. Zabezpieczono dwa przypadki graniczne: 15-klatkowy pierścień nie może zostać uszkodzony przez serię kolejnych IDR, a wyniki asynchroniczne ze starej sesji nie mogą pojawić się po pauzie/reconnect. Testy obejmują te zabezpieczenia oddzielnie od porównania z oryginałem.

Nadal obowiązuje transport ADB, dekoder skonfigurowany dla scrcpy i geometria aplikacji. Nie przeniesiono protokołu Sunshine, HDR, interpolacji iOS 26, wykresów diagnostycznych ani eksperymentalnych dummy events. Kolejna poprawka planowania Metal i eliminacja podwójnej pracy SDL są opisane w [fps-log-investigation-2026-10-13.md](fps-log-investigation-2026-10-13.md). Nie jest to obietnica identycznej wydajności dwóch różnych aplikacji.

## Weryfikacja

`FrameQueueTests.m` kompiluje niezmienioną metodę `_unsafeEnqueue:withDropTarget:` z VoidLink obok produkcyjnej kolejki. Porównuje decyzje odrzucania, liczebność i kolejność na 60 000 operacji, dla każdego ustawienia 0–5. Referencja jest w `tests/reference/VoidLinkQueuePolicy.inc` i zawiera SHA-256 skopiowanej metody. Osobne kontrole obejmują zmianę rozdzielczości, cache formatu, nadejście klatki przed upływem terminu, timeout, stop oraz skrajne przepełnienie IDR.

`FramePresenterTests.m` sprawdza faktyczny presenter na symulatorze: FIFO/prefill, callback na main, nieustawiony timebase, dokładny output PTS, oczekiwanie na klatkę, restart z zaległym asynchronicznym callbackiem, żywy CADisplayLink oraz Standard → Metal → Standard. Testy dekodera sprawdzają również przenoszenie flagi klatki kluczowej. Pozostają wcześniejsze testy GPU, Drawing Toolkit, Androida i zgodności IPA.

120 odrębnych klatek/s i opóźnienie rysowania wymagają testu na iPadzie Pro M2 / iPadOS 17.5.1 z Xiaomi. Większy bufor może wygładzić nierówny dopływ klatek i zwiększyć opóźnienie.

## Pochodzenie

Polityka kolejki: Andy Grundman (Moonlight), port Acaki, modyfikacje TrueZhuanjia (VoidLink), copyright 2025 Moonlight Stream / 2026 TrueZhuanjia. Kod adaptowanej polityki i referencji testowej objęty GPL-3.0; tekst licencji zachowano w `docs/licenses/VoidLink-GPL-3.0.txt`. Istniejące informacje o autorach i licencjach innych części projektu pozostają bez zmian.
