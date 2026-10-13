# Metal: pozostałe mechanizmy VoidLink

Referencja: lokalny VoidLink, commit `2d9558e1`. Zmiany dotyczą prezentacji i przekazywania wyników dekodera. Zależności, Drawing Toolkit, audio, nagrywanie i serwer Androida nie są zmieniane w tym etapie.

## Różnica względem Standard

`ViewControllers/SettingsSwiftUI.swift` (definicje `frameQueueSize` i `asyncFrameDequeue`) ukrywa te ustawienia dla Metal. `Stream/VideoDecoderRenderer.m` nadal ustawia wspólny `FrameQueue.highWaterMark` z `frameQueueSize`. W `Metal/MetalViewController.m` nie ma oczekiwania na zebranie N klatek, które Standard wykonuje przez `_needRequeuing`.

Zatem brak opcji Queue Buffering w Metal nie oznacza braku wewnętrznej kolejki. Nie dodano nowej opcji buforowania Metal. Test uruchamia go z progiem 3 i potwierdza prezentację pierwszej pojedynczej klatki, także przy zablokowanym main.

## Przeniesione mechanizmy

1. `MetalView.m`: stały `NSThread`, QoS user-interactive, autoreleasepool na każdą iterację.
2. `MetalViewController.m`: rezerwacja miejsca w GPU przed pobraniem klatki; sen na semaforze pustego FIFO; budżet pobrania `max(0, 1/fps − averageGPUTime)`.
3. `MetalVideoRenderer.m`: początkowy czas GPU równy połowie interwału klatki, EMA o wadze 0,25; zwalnianie tekstur i flush cache w completion handler; dotychczasowe `afterMinimumDuration` i `waitUntilCompleted` pozostają.
4. `VideoDecoderRenderer.m`: serial queue user-interactive dla przekazania wyników VideoToolbox. Nasza wersja utrzymuje limit trzech prac łącznie z dostarczaniem wyniku i jawnie opróżnia kolejkę przy reset/close.
5. `MetalVideoRenderer.m`: callback prezentacji i czas `presentedTime`; osobne statystyki prezentacji oraz ukończenia GPU. Zerowy czas prezentacji nie zwiększa FPS. Generacja sesji odrzuca spóźnione callbacki po wznowieniu.
6. `MetalView.m`: rozmiar drawable według `screen.nativeScale`.

Przy zatrzymaniu budzimy oczekujący wątek i czekamy na jego wyjście przed ponownym użyciem lub odpięciem warstwy. Nie ma synchronicznego dispatch do main z wątku renderera. Pobieranie miejsca w GPU ma timeout 100 ms; `nextDrawable` ma włączony timeout. Oczekiwanie na rzeczywiste ukończenie GPU pozostaje, jak w referencji.

## Granice przeniesienia

- `Dummy Event`: `ViewControllers/StreamFrameViewController.m`, `setupTimer`, wysyła zdarzenie klawiatury `0xFF` przez protokół Moonlight. Nie przeniesiono tego jako klawisza Androida ani nie przedstawiono dowolnego pakietu no-op ADB jako równoważnika. Opis VoidLink wskazuje zwłaszcza iPadOS 26; nie ma tutaj dowodu korzyści na 17.5.1.
- Interpolacja: `Stream/FrameInterpolator.swift` / konfiguracja VideoToolbox wymaga iOS 26; nie dotyczy iPadOS 17.5.1. Nie wytwarzamy dodatkowych klatek, aby podwyższyć licznik.
- HDR: pominięty zgodnie z wymaganiem użytkownika.
- `CAPABILITY_DIRECT_SUBMIT` / `PULL_RENDERER`: są elementami transportu Moonlight, nie opcjami scrcpy/ADB.
- Flagi VT: zachowano jawne asynchroniczne dekodowanie i limit trzech prac; VoidLink przekazuje flagi 0. Bezpośrednie skopiowanie tej różnicy nie dowodzi poprawy szybkości.
- `optimizeRefreshRate`: metoda referencji jest nieużywana i obniża odświeżanie; nie jest pominiętym przyspieszeniem 120 FPS.

## Interpretacja logów

- `[FramePacing] submitted`: udane przekazania do renderera, nie liczba potwierdzonych prezentacji.
- `[MetalPresentation] presented`: liczba callbacków Metal z dodatnim `presentedTime` w oknie pomiarowym; `maxPresentGapMs` mierzy największy odstęp, a `gpuAverageMs` średnią EMA pracy GPU. Test symulatora nie potwierdza fizycznych 120 Hz.
- `unpresentedCallbacks`: callbacki bez dodatniego czasu, nie pełny licznik wszystkich przyczyn pominięcia klatki.
- `[NativeVideoStats] decodeMeanMs`: od wywołania dekodowania do callbacku, wraz z oczekiwaniem wewnątrz VT; `outputWaitMaxMs`: callback → kolejka odbioru; `slotWaitMaxMs`: oczekiwanie na jeden z trzech slotów.
- `maxPacketGapMs` nadal obejmuje skutki poprzednich prac dekodera / backpressure i nie jest samodzielnym pomiarem sieci.

Znaczenie czasu prezentacji opisuje [Apple: presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime). Ustawienie 120 i pomyślny build nie stanowią dowodu stabilnych 120 FPS: potrzebny jest strumień dostarczający tyle nowych klatek i pomiar na fizycznym iPadzie.

Autorstwo adaptowanych mechanizmów: Acaki / TrueZhuanjia (VoidLink); wspólna polityka kolejki również Andy Grundman (Moonlight). GPL-3.0, tekst w `docs/licenses/VoidLink-GPL-3.0.txt`.
