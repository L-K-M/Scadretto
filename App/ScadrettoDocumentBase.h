#import <AppKit/AppKit.h>

// Concurrent NSDocument creation calls init on AppKit's reading queue.
// This initializer only performs AppKit's required base initialization.
@interface ScadrettoDocumentBase : NSDocument
- (nonnull instancetype)init __attribute__((swift_attr("nonisolated")));
@end
