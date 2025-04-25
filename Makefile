CC := clang

CFLAGS := -fobjc-arc \
          -Wall -Wextra -Wpedantic \
          -framework Foundation \
          -framework AppKit \
          -framework Speech \
          -framework AVFoundation \
          -framework CoreMedia

CFLAGS += -O2 -flto
# CFLAGS += -g -O0

SRCS := main.m audio.m tts.m stt.m

OBJS := $(SRCS:.m=.o)

DEPS := $(OBJS:.o=.d)

TARGET := voice-server

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.m
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

-include $(DEPS)

clean:
	$(RM) $(OBJS) $(DEPS) $(TARGET)

.PHONY: all clean
