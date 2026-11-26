#import "DriveMedia.h"
#import "DriveClient.h"

#define AVMediaType YTKDriveFFmpegMediaType
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/packet.h>
}
#undef AVMediaType
#include <cmath>

NSString *YTKDriveTimestamp(double seconds) {
    int64_t milliseconds = llround(MAX(0, seconds) * 1000);
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld.%03lld",
        (long long)(milliseconds / 3600000), (long long)(milliseconds / 60000 % 60),
        (long long)(milliseconds / 1000 % 60), (long long)(milliseconds % 1000)];
}

static double ParseTimestamp(NSString *value) {
    NSArray<NSString *> *parts = [[value stringByReplacingOccurrencesOfString:@"," withString:@"."]
        componentsSeparatedByString:@":"];
    double seconds = 0;
    for (NSString *part in parts) seconds = seconds * 60 + part.doubleValue;
    return seconds;
}

static void AppendCue(NSMutableArray<NSDictionary *> *cues, double start, double end, NSString *text) {
    NSString *clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length && std::isfinite(start) && std::isfinite(end) && end > MAX(0, start)) {
        [cues addObject:@{@"start":@(MAX(0, start)), @"end":@(end), @"text":clean}];
    }
}

static NSArray<NSDictionary *> *SidecarCues(NSURL *videoURL) {
    NSURL *stem = videoURL.URLByDeletingPathExtension;
    NSString *time = @"((?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3})";
    NSString *format = [NSString stringWithFormat:@"^%@ *--> *%@(?:[ \\t].*)?$", time, time];
    NSRegularExpression *timing = [NSRegularExpression regularExpressionWithPattern:format options:0 error:nil];
    for (NSString *extension in @[@"vtt", @"srt"]) {
        NSURL *file = [stem URLByAppendingPathExtension:extension];
        NSString *contents = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
        if (!contents.length) continue;
        contents = [[contents stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        NSMutableArray<NSDictionary *> *cues = [NSMutableArray array];
        NSMutableArray<NSString *> *text = [NSMutableArray array];
        double start = 0, end = 0;
        BOOL inCue = NO;
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSTextCheckingResult *match = [timing firstMatchInString:trimmed options:0
                range:NSMakeRange(0, trimmed.length)];
            if (match || !trimmed.length) {
                if (inCue) AppendCue(cues, start, end, [text componentsJoinedByString:@"\n"]);
                [text removeAllObjects];
                inCue = match != nil;
                if (match) {
                    start = ParseTimestamp([trimmed substringWithRange:[match rangeAtIndex:1]]);
                    end = ParseTimestamp([trimmed substringWithRange:[match rangeAtIndex:2]]);
                }
            } else if (inCue) {
                [text addObject:line];
            }
        }
        if (inCue) AppendCue(cues, start, end, [text componentsJoinedByString:@"\n"]);
        if (cues.count) return cues;
    }
    return @[];
}

static NSArray<NSDictionary *> *EmbeddedCues(NSURL *url, BOOL (^cancelled)(void)) {
    AVFormatContext *context = NULL;
    // A download is a local file. Reject external references opened by a demuxer.
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int status = avformat_open_input(&context, url.fileSystemRepresentation, NULL, &options);
    av_dict_free(&options);
    if (status < 0) return @[];

    AVStream *subtitle = NULL;
    for (unsigned int i = 0; i < context->nb_streams; i++) {
        AVStream *stream = context->streams[i];
        if (stream->codecpar->codec_id == AV_CODEC_ID_MOV_TEXT) {
            if (!subtitle || (stream->disposition & AV_DISPOSITION_DEFAULT)) subtitle = stream;
        }
    }
    if (subtitle) {
        for (unsigned int i = 0; i < context->nb_streams; i++) {
            if (context->streams[i] != subtitle) context->streams[i]->discard = AVDISCARD_ALL;
        }
    }
    NSMutableArray<NSDictionary *> *cues = [NSMutableArray array];
    AVPacket *packet = subtitle ? av_packet_alloc() : NULL;
    double origin = context->start_time == AV_NOPTS_VALUE ? 0 : (double)context->start_time / AV_TIME_BASE;
    while (packet && !cancelled() && av_read_frame(context, packet) >= 0) {
        if (packet->stream_index == subtitle->index && packet->size > 2 &&
            packet->pts != AV_NOPTS_VALUE && packet->duration > 0) {
            int length = (packet->data[0] << 8) | packet->data[1];
            if (length > 0 && length <= packet->size - 2) {
                @autoreleasepool {
                    NSString *text = [[NSString alloc] initWithBytes:packet->data + 2
                        length:(NSUInteger)length encoding:NSUTF8StringEncoding];
                    double unit = av_q2d(subtitle->time_base);
                    double start = packet->pts * unit - origin;
                    AppendCue(cues, start, start + packet->duration * unit, text ?: @"");
                }
            }
        }
        av_packet_unref(packet);
    }
    av_packet_free(&packet);
    avformat_close_input(&context);
    return cues;
}

NSDictionary<NSString *, NSData *> *YTKDriveCaptionFiles(NSURL *videoURL,
    BOOL (^cancelled)(void), NSError **error) {
    NSArray<NSDictionary *> *cues = SidecarCues(videoURL);
    if (!cues.count && !cancelled()) cues = EmbeddedCues(videoURL, cancelled);
    if (cancelled()) return nil;
    if (!cues.count) {
        if (error) *error = YTKDriveError(@"No timed captions were saved. Download the video again with subtitles enabled.");
        return nil;
    }

    return YTKDriveCaptionFilesFromCues(cues);
}

NSDictionary<NSString *, NSData *> *YTKDriveCaptionFilesFromCues(NSArray<NSDictionary *> *cues) {
    NSMutableString *plain = [NSMutableString string];
    NSMutableString *webvtt = [NSMutableString stringWithString:@"WEBVTT\n\n"];
    for (NSDictionary *cue in cues) {
        NSString *start = YTKDriveTimestamp([cue[@"start"] doubleValue]);
        NSString *end = YTKDriveTimestamp([cue[@"end"] doubleValue]);
        NSString *text = cue[@"text"];
        [plain appendFormat:@"[%@ – %@] %@\n", start, end, text];
        NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
            stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
        for (NSString *line in [escaped componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (line.length) [nonempty addObject:line];
        }
        [webvtt appendFormat:@"%@ --> %@\n%@\n\n", start, end, [nonempty componentsJoinedByString:@"\n"]];
    }
    return @{@"transcript.txt":[plain dataUsingEncoding:NSUTF8StringEncoding],
             @"transcript.vtt":[webvtt dataUsingEncoding:NSUTF8StringEncoding]};
}
