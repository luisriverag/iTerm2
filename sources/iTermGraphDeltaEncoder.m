//
//  iTermGraphDeltaEncoder.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 7/28/20.
//

#import "iTermGraphDeltaEncoder.h"

#import "DebugLogging.h"
#import "NSArray+iTerm.h"
#import "iTermOrderedDictionary.h"

@implementation iTermGraphDeltaEncoder

- (instancetype)initWithPreviousRevision:(iTermEncoderGraphRecord * _Nullable)previousRevision {
    return [self initWithKey:@""
                  identifier:@""
                  generation:previousRevision.generation + 1
            previousRevision:previousRevision];
}

- (instancetype)initWithKey:(NSString *)key
                 identifier:(NSString *)identifier
                 generation:(NSInteger)generation
           previousRevision:(iTermEncoderGraphRecord * _Nullable)previousRevision {
    assert(identifier);
    self = [super initWithKey:key identifier:identifier generation:generation];
    if (self) {
        if (previousRevision && !previousRevision.rowid) {
            ITBetaAssert(NO, @"Previous revision lacks a rowID: %@", previousRevision);
        }
        _previousRevision = previousRevision;
    }
    return self;
}

- (void)encodeChildrenWithKey:(NSString *)key
                  identifiers:(NSArray<NSString *> *)identifiers
                   generation:(NSInteger)generation
                        block:(BOOL (^)(NSString * _Nonnull,
                                        NSUInteger,
                                        iTermGraphEncoder * _Nonnull,
                                        BOOL * _Nonnull))block {
    if (identifiers.count > 16 && _previousRevision.graphRecords.count > 16) {
        // Avoid quadratic complexity when encoding a big child into a big array.
        // Each of `identifiers` needs to check if it exists in `_previousRevision`.
        [_previousRevision ensureIndexOfGraphRecords];
    }
    [super encodeChildrenWithKey:key identifiers:identifiers generation:generation block:block];
}

- (BOOL)encodeChildWithKey:(NSString *)key
                identifier:(NSString *)identifier
                generation:(NSInteger)generation
                     block:(BOOL (^ NS_NOESCAPE)(iTermGraphEncoder *subencoder))block {
    // This is called N times for N identifiers in a single array `key`
    iTermEncoderGraphRecord *record = [_previousRevision childRecordWithKey:key
                                                                 identifier:identifier];
    if (!record) {
        // A wholly new key+identifier
        [super encodeChildWithKey:key identifier:identifier generation:generation block:block];
        return YES;
    }
    if (record.generation == generation) {
        // No change to generation
        DLog(@"Record %@[%@] at generation %@ didn't change", key, identifier, @(generation));
        [self encodeGraph:record];
        return YES;
    }
    // Same key+id, new generation.
    NSInteger realGeneration = generation;
    if (generation == iTermGenerationAlwaysEncode) {
        realGeneration = record.generation + 1;
    }
    // For reasons I don't entirely understand we were hitting this assertion. My guess is that
    // it is nondeterminism in copy-on-write behavior in LineBlock that sometimes you get the
    // mutation thread's instance and sometimes you get a copy. I don't think it's harmful to go
    // backwards in generation; as long as they are unequal we'll simply encode it. Issue 11819.
#if DEBUG
    assert(record.generation < generation);
#endif
    iTermGraphEncoder *encoder = [[iTermGraphDeltaEncoder alloc] initWithKey:key
                                                                  identifier:identifier
                                                                  generation:realGeneration
                                                            previousRevision:record];
    if (!block(encoder)) {
        return NO;
    }
    [self encodeGraph:encoder.record];
    return YES;
}

- (BOOL)enumerateRecords:(void (^)(iTermEncoderGraphRecord * _Nullable before,
                                   iTermEncoderGraphRecord * _Nullable after,
                                   NSNumber *parent,
                                   NSString *path,
                                   BOOL *stop))block {
    BOOL stop = NO;
    @try {
        block(_previousRevision, self.record, @0, @"root", &stop);
    } @catch (NSException *exception) {
        [exception it_rethrowWithMessage:@"(1) %@ vs %@",
         _previousRevision.compactDescription,
         self.record.compactDescription];
    }

    if (stop) {
        return NO;
    }
    return [self enumerateBefore:_previousRevision after:self.record parent:self.record.rowid path:@"root" block:block];
}

- (BOOL)enumerateBefore:(iTermEncoderGraphRecord *)preRecord
                  after:(iTermEncoderGraphRecord *)postRecord
                 parent:(NSNumber *)parent
                   path:(NSString *)path
                  block:(void (^)(iTermEncoderGraphRecord * _Nullable before,
                                  iTermEncoderGraphRecord * _Nullable after,
                                  NSNumber *parent,
                                  NSString *path,
                                  BOOL *stop))block {
    iTermOrderedDictionary<iTermTuple<NSString *, NSString *> *, iTermEncoderGraphRecord *> *beforeDict =
    [iTermOrderedDictionary byMapping:preRecord.graphRecords ?: @[] block:^id _Nonnull(NSUInteger index,
                                                                                       iTermEncoderGraphRecord * _Nonnull record) {
        return [iTermTuple tupleWithObject:record.key andObject:record.identifier];
    }];
    iTermOrderedDictionary<iTermTuple<NSString *, NSString *> *, iTermEncoderGraphRecord *> *afterDict =
    [iTermOrderedDictionary byMapping:postRecord.graphRecords block:^id _Nonnull(NSUInteger index,
                                                                                iTermEncoderGraphRecord * _Nonnull record) {
        return [iTermTuple tupleWithObject:record.key andObject:record.identifier];
    }];
    __block BOOL ok = YES;
    void (^handle)(iTermTuple<NSString *, NSString *> *,
                   iTermEncoderGraphRecord *,
                   NSString *,
                   BOOL *) = ^(iTermTuple<NSString *, NSString *> *key,
                               iTermEncoderGraphRecord *record,
                               NSString *path,
                               BOOL *stop) {
        iTermEncoderGraphRecord *before = beforeDict[key];
        iTermEncoderGraphRecord *after = afterDict[key];
        @try {
            block(before, after, parent, path, stop);
        } @catch (NSException *exception) {
            [exception it_rethrowWithMessage:@"(2) %@ [%@] vs %@ [%@]",
             before.compactDescription,
             beforeDict.debugString,
             after.compactDescription,
             afterDict.debugString];
        }
        @try {
            // Now recurse for their descendants.
            ok = [self enumerateBefore:before
                                 after:after
                                parent:before ? before.rowid : after.rowid
                                  path:path
                                 block:block];
        } @catch (NSException *exception) {
            [exception it_rethrowWithMessage:@"(3) %@ [%@] vs %@ [%@]",
             before.compactDescription,
             beforeDict.debugString,
             after.compactDescription,
             afterDict.debugString];
        }
    };
    NSMutableSet<iTermTuple<NSString *, NSString *> *> *seenKeys = [NSMutableSet set];
    [beforeDict.keys enumerateObjectsUsingBlock:^(iTermTuple<NSString *, NSString *> * _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
        handle(key, beforeDict[key], [NSString stringWithFormat:@"%@.%@[%@]",
                                      path, key.firstObject, key.secondObject], stop);
        [seenKeys addObject:key];
    }];
    if (!ok) {
        return NO;
    }
    [afterDict.keys enumerateObjectsUsingBlock:^(iTermTuple<NSString *, NSString *> * _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([seenKeys containsObject:key]) {
            return;
        }
        handle(key, afterDict[key], [NSString stringWithFormat:@"%@.%@[%@]",
                                     path, key.firstObject, key.secondObject], stop);
    }];
    return ok;
}


@end
