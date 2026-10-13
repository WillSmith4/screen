// Verbatim _unsafeEnqueue:withDropTarget: from VoidLink 2d9558e1.
// Copyright 2025 Moonlight Stream, 2026 TrueZhuanjia. GPL-3.0.
// Andy Grundman / Acaki / TrueZhuanjia. See docs/licenses/VoidLink-GPL-3.0.txt.
// Body SHA256: 791204f84765fcf88b56d45d92d77712a30bc0535a8a1d6164fb7b014567efeb
- (int)_unsafeEnqueue:(Frame *)frame withDropTarget:(int)frameDropTarget {
    int dropCount = 0;
    // Always accept IDR frames, allow exceeding HWM
    if (frame.frameType == FRAME_TYPE_IDR || _count < frameDropTarget) {
        [self _pushFrame:frame];
        _droppedLast = NO;
    } else {
        if (!_droppedLast) {
			// alternate between: drop newest...
            [self _noteDroppedFrame:frame];
            dropCount = 1;
            _droppedLast = YES;
        } else {
            // and: drop oldest & enqueue new
            if ([self _peekFrame].frameType != FRAME_TYPE_IDR) {
				Frame *oldest = [self _popFrame];
                [oldest setDurationFromNext:[self _peekFrame]];
                [self _noteDroppedFrame:oldest];
                dropCount = 1;
            }
            [self _pushFrame:frame];
            _droppedLast = NO;
        }
    }
	// regardless of drop status, every enqueue is a frame
    // for estimatedFramerate purposes
    _framesIn++;
    [_frameDropMetrics addValue:(float)dropCount];

    // Stats displays the soft cap
    _currentSoftCap = frameDropTarget;
    return dropCount;
}
