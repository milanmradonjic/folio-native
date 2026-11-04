// PDFium runs only here, never in the AppKit process. Requests and results use bounded stdio.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <sys/resource.h>
#include <unistd.h>
#include <cmath>
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <vector>
#include "fpdfview.h"
#include "fpdf_edit.h"
#include "fpdf_text.h"
#include "fpdf_save.h"
#include "fpdf_signature.h"
#include "fpdf_transformpage.h"

static constexpr size_t LIMIT = 64 * 1024 * 1024;
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static NSData *readBytes(size_t length) {
    require(length <= LIMIT, "This PDF is too large for content editing (64 MiB maximum).");
    NSMutableData *result = [NSMutableData dataWithLength:length];
    size_t done = 0;
    while (done < length) {
        ssize_t count = read(STDIN_FILENO, (char *)result.mutableBytes + done, length - done);
        require(count > 0, "The editor request was incomplete."); done += (size_t)count;
    }
    return result;
}
static void writeBytes(NSData *data) {
    size_t done = 0;
    while (done < data.length) {
        ssize_t count = write(STDOUT_FILENO, (const char *)data.bytes + done, data.length - done);
        require(count > 0, "The editor connection closed."); done += (size_t)count;
    }
}
static void reply(NSDictionary *header, NSData *body = nil) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:header options:0 error:nil];
    writeBytes(json); writeBytes([@"\n" dataUsingEncoding:NSUTF8StringEncoding]);
    if (body) writeBytes(body);
}
static NSDictionary *textByObject(FPDF_TEXTPAGE page) {
    int count = FPDFText_CountChars(page);
    require(count >= 0 && count <= 200000, "This page has too much text to edit.");
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (int index = 0; index < count; ++index) {
        if (FPDFText_IsGenerated(page, index)) continue;
        FPDF_PAGEOBJECT object = FPDFText_GetTextObject(page, index);
        unsigned int scalar = FPDFText_GetUnicode(page, index);
        if (!object || !scalar || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) continue;
        NSValue *key = [NSValue valueWithPointer:object];
        NSMutableString *text = result[key];
        if (!text) { text = [NSMutableString string]; result[key] = text; }
        unichar units[2]; NSUInteger length = 1;
        if (scalar <= 0xffff) units[0] = (unichar)scalar;
        else { scalar -= 0x10000; units[0] = 0xd800 + (scalar >> 10); units[1] = 0xdc00 + (scalar & 1023); length = 2; }
        [text appendString:[[NSString alloc] initWithCharacters:units length:length]];
        require(text.length <= 32767, "This text run is too large to edit.");
    }
    return result;
}
static bool sameStyle(FPDF_PAGEOBJECT a, FPDF_PAGEOBJECT b) {
    FS_MATRIX ma{}, mb{}; float sa = 0, sb = 0;
    if (!FPDFPageObj_GetMatrix(a, &ma) || !FPDFPageObj_GetMatrix(b, &mb) ||
        !FPDFTextObj_GetFontSize(a, &sa) || !FPDFTextObj_GetFontSize(b, &sb)) return false;
    if (FPDFTextObj_GetFont(a) != FPDFTextObj_GetFont(b) || sa != sb ||
        ma.a != mb.a || ma.b != 0 || mb.b != 0 || ma.c != 0 || mb.c != 0 ||
        ma.d != mb.d || ma.f != mb.f || ma.a <= 0 || ma.d <= 0 || mb.e <= ma.e ||
        FPDFTextObj_GetTextRenderMode(a) != FPDFTextObj_GetTextRenderMode(b) ||
        FPDFPageObj_GetMarkedContentID(a) != FPDFPageObj_GetMarkedContentID(b)) return false;
    unsigned int ar, ag, ab, aa, br, bg, bb, ba;
    if (!FPDFPageObj_GetFillColor(a, &ar, &ag, &ab, &aa) || !FPDFPageObj_GetFillColor(b, &br, &bg, &bb, &ba) ||
        ar != br || ag != bg || ab != bb || aa != ba) return false;
    if (!FPDFPageObj_GetStrokeColor(a, &ar, &ag, &ab, &aa) || !FPDFPageObj_GetStrokeColor(b, &br, &bg, &bb, &ba) ||
        ar != br || ag != bg || ab != bb || aa != ba) return false;
    return true;
}
static NSArray *targetsForPage(FPDF_PAGE page) {
    int count = FPDFPage_CountObjects(page);
    require(count >= 0 && count <= 20000, "This page has too many objects to edit.");
    FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page);
    require(textPage != nullptr, "Couldn't read this page.");
    NSMutableArray *targets = [NSMutableArray array];
    @try {
        NSDictionary *texts = textByObject(textPage);
        FPDF_PAGEOBJECT previous = nullptr; NSMutableDictionary *last = nil;
        for (int i = 0; i < count; ++i) {
            FPDF_PAGEOBJECT object = FPDFPage_GetObject(page, i);
            int type = FPDFPageObj_GetType(object);
            float l, b, r, t;
            if (!FPDFPageObj_GetBounds(object, &l, &b, &r, &t) ||
                !std::isfinite(l) || !std::isfinite(b) || !std::isfinite(r) || !std::isfinite(t) || r < l || t < b) {
                [targets addObject:@{@"index": @(i), @"end": @(i), @"kind": @"object", @"text": @"Page object (no visible bounds)", @"box": @[@0, @0, @0.5, @0.5]}];
                previous = nullptr; last = nil; continue;
            }
            if (r == l) r = l + 0.5f;
            if (t == b) t = b + 0.5f;
            if (type != FPDF_PAGEOBJ_TEXT && type != FPDF_PAGEOBJ_IMAGE) {
                NSString *label = type == FPDF_PAGEOBJ_FORM ? @"Grouped artwork" : type == FPDF_PAGEOBJ_PATH ? @"Vector path" : type == FPDF_PAGEOBJ_SHADING ? @"Shading" : @"Page object";
                [targets addObject:@{@"index": @(i), @"end": @(i), @"kind": @"object", @"text": label, @"box": @[@(l), @(b), @(r), @(t)]}];
                previous = nullptr; last = nil; continue;
            }
            if (type == FPDF_PAGEOBJ_IMAGE) {
                [targets addObject:@{@"index": @(i), @"end": @(i), @"kind": @"image", @"text": @"Embedded image", @"box": @[@(l), @(b), @(r), @(t)]}];
                previous = nullptr; last = nil; continue;
            }
            int mode = FPDFTextObj_GetTextRenderMode(object);
            if (mode < 0 || mode > 2 || ![texts[[NSValue valueWithPointer:object]] length]) {
                [targets addObject:@{@"index": @(i), @"end": @(i), @"kind": @"object", @"text": @"Text object", @"box": @[@(l), @(b), @(r), @(t)]}];
                previous = nullptr; last = nil; continue;
            }
            NSString *text = texts[[NSValue valueWithPointer:object]] ?: @"";
            if (!text.length) { previous = nullptr; last = nil; continue; }
            FS_MATRIX matrix{}; float size = 0;
            if (!FPDFPageObj_GetMatrix(object, &matrix) || !FPDFTextObj_GetFontSize(object, &size)) continue;
            float pl = 0, pb = 0, pr = 0, pt = 0;
            bool join = previous && last && [last[@"end"] intValue] == i - 1 && sameStyle(previous, object) &&
                FPDFPageObj_GetBounds(previous, &pl, &pb, &pr, &pt);
            float gap = matrix.e - pr, em = size * matrix.a;
            if (join && gap >= -0.25 * em && gap < 0.65 * em) {
                NSString *old = last[@"text"];
                bool space = gap > 0.16 * em && ![old hasSuffix:@" "] && ![text hasPrefix:@" "];
                last[@"text"] = [old stringByAppendingFormat:@"%@%@", space ? @" " : @"", text];
                require([last[@"text"] length] <= 32767, "This text run is too large to edit.");
                NSArray *box = last[@"box"];
                last[@"box"] = @[@(fmin([box[0] floatValue], l)), @(fmin([box[1] floatValue], b)),
                                 @(fmax([box[2] floatValue], r)), @(fmax([box[3] floatValue], t))];
                last[@"end"] = @(i);
            } else {
                last = [@{@"index": @(i), @"end": @(i), @"kind": @"text", @"text": text,
                          @"box": @[@(l), @(b), @(r), @(t)]} mutableCopy];
                [targets addObject:last];
            }
            previous = object;
        }
    } @finally { FPDFText_ClosePage(textPage); }
    require(targets.count <= 10000, "This page has too many editable items.");
    return targets;
}
struct Writer : FPDF_FILEWRITE {
    NSMutableData *data;
    Writer() : data([NSMutableData data]) {
        version = 1;
        WriteBlock = [](FPDF_FILEWRITE *base, const void *bytes, unsigned long size) -> int {
            auto *self = static_cast<Writer *>(base);
            if (size > LIMIT || self->data.length > LIMIT - size) return 0;
            [self->data appendBytes:bytes length:size]; return 1;
        };
    }
};
static NSData *saveDocument(FPDF_DOCUMENT document) {
    Writer writer;
    require(FPDF_SaveAsCopy(document, &writer, FPDF_NO_INCREMENTAL), "Couldn't save the edited PDF.");
    return writer.data;
}
static bool clippingPreservesBounds(FPDF_PAGEOBJECT object) {
    FPDF_CLIPPATH clip = FPDFPageObj_GetClipPath(object);
    if (!clip) return true;
    int paths = FPDFClipPath_CountPaths(clip);
    // PDFium returns -1 when this object's clip container has no backing path.
    if (paths == -1) return true;
    if (paths <= 0 || paths > 32) return false;
    float left, bottom, right, top;
    if (!FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top)) return false;
    for (int path = 0; path < paths; ++path) {
        int count = FPDFClipPath_CountPathSegments(clip, path);
        if (count != 4 && count != 5) return false;
        std::vector<FS_POINTF> points;
        for (int segment = 0; segment < count; ++segment) {
            FPDF_PATHSEGMENT handle = FPDFClipPath_GetPathSegment(clip, path, segment);
            int type = FPDFPathSegment_GetType(handle);
            FS_POINTF point{};
            if (type != (segment == 0 ? FPDF_SEGMENT_MOVETO : FPDF_SEGMENT_LINETO) ||
                !FPDFPathSegment_GetPoint(handle, &point.x, &point.y)) return false;
            points.push_back(point);
        }
        if (count == 5) {
            if (points[4].x != points[0].x || points[4].y != points[0].y) return false;
            points.pop_back();
        }
        float l = points[0].x, r = l, b = points[0].y, t = b;
        for (int i = 0; i < 4; ++i) {
            const auto &a = points[i], &next = points[(i + 1) % 4];
            if ((a.x == next.x) == (a.y == next.y)) return false;
            l = fmin(l, a.x); r = fmax(r, a.x); b = fmin(b, a.y); t = fmax(t, a.y);
        }
        if (l > left + 0.01 || b > bottom + 0.01 || r < right - 0.01 || t < top - 0.01) return false;
    }
    return true;
}
static void changeText(FPDF_PAGE page, NSDictionary *target, NSString *text) {
    require(text && text.length <= 32767 && [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound,
            "Enter one line of text, without control characters.");
    int first = [target[@"index"] intValue], end = [target[@"end"] intValue];
    FPDF_PAGEOBJECT object = FPDFPage_GetObject(page, first);
    for (int i = end; i >= first + (text.length ? 1 : 0); --i) {
        FPDF_PAGEOBJECT fragment = FPDFPage_GetObject(page, i);
        require(FPDFPage_RemoveObject(page, fragment), "Couldn't replace this complete text run.");
        FPDFPageObj_Destroy(fragment);
    }
    if (text.length) {
        std::vector<unsigned short> buffer(text.length + 1, 0);
        [text getCharacters:buffer.data() range:NSMakeRange(0, text.length)];
        require(FPDFText_SetText(object, buffer.data()), "Couldn't change this text.");
        FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page);
        require(textPage != nullptr, "Couldn't verify the replacement text.");
        NSString *actual;
        @try { actual = textByObject(textPage)[[NSValue valueWithPointer:object]] ?: @""; } @finally { FPDFText_ClosePage(textPage); }
        require([actual isEqualToString:text], "The original font cannot display all those characters. Try characters already present in the document.");
    }
}
static void changeImage(FPDF_DOCUMENT document, FPDF_PAGE page, FPDF_PAGEOBJECT object, NSData *image, NSArray *box) {
    require(image.length > 0 && image.length <= 24 * 1024 * 1024, "Choose a PNG or JPEG under 24 MiB.");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)image, nullptr);
    require(source != nullptr, "Couldn't read the replacement image.");
    @try {
        NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
        require([type isEqualToString:@"public.png"] || [type isEqualToString:@"public.jpeg"], "Choose a PNG or JPEG image.");
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
        size_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
        size_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
        require(width > 0 && height > 0 && width <= 20000 && height <= 20000 && width * height <= 20000000,
                "Choose an image under 20 megapixels.");
        CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
        require(decoded != nullptr, "Couldn't decode the image.");
        FPDF_BITMAP bitmap = FPDFBitmap_Create((int)width, (int)height, 1);
        if (!bitmap) { CGImageRelease(decoded); throw std::runtime_error("Couldn't allocate the image."); }
        @try {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(FPDFBitmap_GetBuffer(bitmap), width, height, 8,
                FPDFBitmap_GetStride(bitmap), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(space);
            if (!context) { CGImageRelease(decoded); throw std::runtime_error("Couldn't prepare the image."); }
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), decoded);
            CGContextRelease(context); CGImageRelease(decoded);
            // PDFium expects straight BGRA, while Core Graphics draws premultiplied components.
            auto *pixels = (unsigned char *)FPDFBitmap_GetBuffer(bitmap);
            int stride = FPDFBitmap_GetStride(bitmap);
            bool opaque = true;
            for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
                auto *p = pixels + y * stride + 4 * x;
                opaque = opaque && p[3] == 255;
                if (p[3] > 0 && p[3] < 255) for (int c = 0; c < 3; ++c) p[c] = (unsigned char)std::min(255, (p[c] * 255 + p[3] / 2) / p[3]);
            }
            if (opaque) {
                FPDF_BITMAP solid = FPDFBitmap_Create((int)width, (int)height, 0);
                require(solid != nullptr, "Couldn't allocate the image.");
                for (size_t y = 0; y < height; ++y) memcpy((char *)FPDFBitmap_GetBuffer(solid) + y * FPDFBitmap_GetStride(solid), pixels + y * stride, width * 4);
                FPDFBitmap_Destroy(bitmap); bitmap = solid;
            }
            if (box) {
                object = FPDFPageObj_NewImageObj(document);
                require(object != nullptr, "Couldn't create an image placement.");
                if (!FPDFImageObj_SetBitmap(nullptr, 0, object, bitmap)) { FPDFPageObj_Destroy(object); throw std::runtime_error("Couldn't insert the image."); }
                FS_MATRIX matrix{[box[2] floatValue] - [box[0] floatValue], 0, 0,
                                 [box[3] floatValue] - [box[1] floatValue], [box[0] floatValue], [box[1] floatValue]};
                if (!FPDFPageObj_SetMatrix(object, &matrix)) { FPDFPageObj_Destroy(object); throw std::runtime_error("Couldn't position the image."); }
                require(FPDFPage_InsertObject(page, object), "Couldn't insert the image.");
            } else {
                // SetBitmap mutates the image resource shared by placements on this page.
                // Build a distinct placement at the same stacking index instead.
                require(clippingPreservesBounds(object),
                        "Replacing clipped images is not supported. The original image has not changed.");
                for (int i = 0; i < FPDFPage_CountObjects(page); ++i) {
                    FPDF_PAGEOBJECT item = FPDFPage_GetObject(page, i);
                    if (FPDFPageObj_GetType(item) == FPDF_PAGEOBJ_TEXT) {
                        int mode = FPDFTextObj_GetTextRenderMode(item);
                        require(mode < 4 || mode > 7, "Image replacement on pages with text clipping is not supported.");
                    }
                }
                require(!FPDFPageObj_HasTransparency(object),
                        "Replacing images with transparency or blend effects is not supported. The original image has not changed.");
                FS_MATRIX matrix{};
                require(FPDFPageObj_GetMatrix(object, &matrix), "Couldn't preserve this image's placement.");
                int index = -1;
                for (int i = 0; i < FPDFPage_CountObjects(page); ++i) if (FPDFPage_GetObject(page, i) == object) { index = i; break; }
                require(index >= 0, "Select this image again.");
                FPDF_PAGEOBJECT replacement = FPDFPageObj_NewImageObj(document);
                require(replacement != nullptr, "Couldn't create the replacement image.");
                bool owned = true;
                try {
                    require(FPDFImageObj_SetBitmap(nullptr, 0, replacement, bitmap) && FPDFPageObj_SetMatrix(replacement, &matrix),
                            "Couldn't prepare the replacement image.");
                    int marks = FPDFPageObj_CountMarks(object);
                    require(marks >= 0 && marks <= 128, "This image has too many content tags to replace.");
                    for (int i = 0; i < marks; ++i) require(FPDFPageObj_AddExistingMark(replacement, FPDFPageObj_GetMark(object, i)), "Couldn't preserve the image's content tags.");
                    require(FPDFPage_RemoveObject(page, object), "Couldn't remove this image placement.");
                    FPDFPageObj_Destroy(object);
                    owned = false;
                    require(FPDFPage_InsertObjectAtIndex(page, replacement, (size_t)index), "Couldn't insert the replacement image.");
                } catch (...) { if (owned) FPDFPageObj_Destroy(replacement); throw; }
            }
        } @finally { FPDFBitmap_Destroy(bitmap); }
    } @finally { CFRelease(source); }
}
static void processRequest(NSDictionary *request, NSData *pdf, NSData *image) {
    FPDF_DOCUMENT document = FPDF_LoadMemDocument64(pdf.bytes, pdf.length, nullptr);
    require(document != nullptr, "Couldn't open this PDF for content editing.");
    @try {
        require(FPDF_GetSecurityHandlerRevision(document) == -1 && FPDF_GetSignatureCount(document) == 0,
                "Content editing requires an unsigned, unencrypted PDF.");
        int pageNumber = [request[@"page"] intValue];
        require(pageNumber >= 0 && pageNumber < FPDF_GetPageCount(document), "Choose a valid page.");
        FPDF_PAGE page = FPDF_LoadPage(document, pageNumber);
        require(page != nullptr, "Couldn't open this page.");
        @try {
            NSString *operation = request[@"operation"];
            NSArray *targets = targetsForPage(page);
            if ([operation isEqualToString:@"inspect"]) { reply(@{@"ok": @YES, @"bytes": @0, @"targets": targets}); return; }
            if ([operation isEqualToString:@"delete"]) {
                NSDictionary *target = nil;
                for (NSDictionary *candidate in targets) if ([candidate[@"index"] isEqual:request[@"index"]]) { target = candidate; break; }
                require(target != nil, "Select this object again.");
                for (int index = [target[@"end"] intValue]; index >= [target[@"index"] intValue]; --index) {
                    FPDF_PAGEOBJECT object = FPDFPage_GetObject(page, index);
                    require(FPDFPage_RemoveObject(page, object), "Couldn't delete the selected object.");
                    FPDFPageObj_Destroy(object);
                }
            } else if ([operation isEqualToString:@"insertImage"]) {
                NSArray *box = request[@"box"];
                require([box isKindOfClass:NSArray.class] && box.count == 4, "Choose an image placement.");
                for (NSNumber *value in box) require([value isKindOfClass:NSNumber.class] && std::isfinite(value.doubleValue), "Invalid image placement.");
                require([box[2] doubleValue] > [box[0] doubleValue] && [box[3] doubleValue] > [box[1] doubleValue], "Choose a nonempty image placement.");
                changeImage(document, page, nullptr, image, box);
            } else {
                require([operation isEqualToString:@"text"] || [operation isEqualToString:@"image"], "Unknown editor operation.");
                NSDictionary *target = nil;
                for (NSDictionary *candidate in targets) if ([candidate[@"index"] isEqual:request[@"index"]] && [candidate[@"kind"] isEqual:operation]) { target = candidate; break; }
                require(target != nil, "Select this item again.");
                if ([operation isEqualToString:@"text"]) {
                    require([request[@"text"] isKindOfClass:NSString.class], "Enter replacement text.");
                    changeText(page, target, request[@"text"]);
                } else changeImage(document, page, FPDFPage_GetObject(page, [target[@"index"] intValue]), image, nil);
            }
            require(FPDFPage_GenerateContent(page), "Couldn't regenerate the edited page.");
        } @finally { FPDF_ClosePage(page); }
        NSData *result = saveDocument(document);
        reply(@{@"ok": @YES, @"bytes": @(result.length)}, result);
    } @finally { FPDF_CloseDocument(document); }
}
int main() {
    @autoreleasepool {
        struct rlimit cpu{30, 35}; setrlimit(RLIMIT_CPU, &cpu);
        struct rlimit core{0, 0}; setrlimit(RLIMIT_CORE, &core);
        FPDF_InitLibrary();
        try {
            NSMutableData *header = [NSMutableData data]; unsigned char c = 0;
            while (read(STDIN_FILENO, &c, 1) == 1 && c != '\n') {
                require(header.length < 65536, "Editor header too large."); [header appendBytes:&c length:1];
            }
            require(c == '\n', "The editor request was incomplete.");
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:header options:0 error:nil];
            require([request isKindOfClass:NSDictionary.class] && [request[@"page"] isKindOfClass:NSNumber.class] &&
                    [request[@"pdfLength"] isKindOfClass:NSNumber.class] && [request[@"imageLength"] isKindOfClass:NSNumber.class], "Invalid editor request.");
            NSData *pdf = readBytes([request[@"pdfLength"] unsignedLongLongValue]);
            NSData *image = readBytes([request[@"imageLength"] unsignedLongLongValue]);
            processRequest(request, pdf, image);
        } catch (const std::exception &error) {
            try { reply(@{@"ok": @NO, @"bytes": @0, @"error": [NSString stringWithUTF8String:error.what()] ?: @"The editor failed."}); } catch (...) {}
            FPDF_DestroyLibrary(); return 1;
        }
        FPDF_DestroyLibrary(); return 0;
    }
}
