-define(KEY_BACKSPACE, 127).
-define(KEY_CTRLA, 1).
-define(KEY_CTRLE, 5).
-define(KEY_CTRLD, 4).
-define(KEY_ENTER, 10).
-define(KEY_TEXT_RANGE(X), % ignore control codes
        (not(X < 32) andalso
         not(X >= 127 andalso X < 160))).

-define(EXEC_LINES, 15).
-define(MAX_VALIDATION_DELAY, 150). % longest time to validate input, in ms
