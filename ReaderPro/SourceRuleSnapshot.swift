import Foundation

// Copy value-based rule context to GCD workers; JavaScriptCore values never cross threads.
struct SourceRuleSnapshot {
    private let deadline = LegadoJSCtx.deadline
    private let sourceUrl = LegadoJSCtx.sourceUrl
    private let key = LegadoJSCtx.key
    private let page = LegadoJSCtx.page
    private let book = LegadoJSCtx.book
    private let chapter = LegadoJSCtx.chapter
    private let library = LegadoJSCtx.library
    private let comment = LegadoJSCtx.comment
    private let variableComment = LegadoJSCtx.variableComment
    private let ruleSource = LegadoJSCtx.ruleSource
    private let loginURL = LegadoJSCtx.loginURL
    private let strictContentHTTP = LegadoJSCtx.strictContentHTTP
    private let failures = LegadoJSCtx.failures
    private let headers = LegadoJSCtx.headers
    private let mediaCapture = LegadoJSCtx.mediaCapture
    private let tls = SourceTLS.allowsInvalidCertificates
    private let session = SourceHTTP.testSession
    func perform<T>(_ operation: () throws -> T) rethrows -> T {
        try LegadoJSCtx.$deadline.withValue(deadline) {
            try LegadoJSCtx.$sourceUrl.withValue(sourceUrl) {
                try LegadoJSCtx.$key.withValue(key) {
                    try LegadoJSCtx.$page.withValue(page) {
                        try LegadoJSCtx.$book.withValue(book) {
                            try LegadoJSCtx.$chapter.withValue(chapter) {
                                try LegadoJSCtx.$library.withValue(library) {
                                    try LegadoJSCtx.$comment.withValue(comment) {
                                        try LegadoJSCtx.$variableComment.withValue(variableComment) {
                                            try LegadoJSCtx.$ruleSource.withValue(ruleSource) {
                                                try LegadoJSCtx.$loginURL.withValue(loginURL) {
                                                    try LegadoJSCtx.$strictContentHTTP.withValue(strictContentHTTP) {
                                                        try LegadoJSCtx.$failures.withValue(failures) {
                                                            try LegadoJSCtx.$headers.withValue(headers) {
                                                                try LegadoJSCtx.$mediaCapture.withValue(mediaCapture) {
                                                                    try SourceTLS.$allowsInvalidCertificates.withValue(tls) {
                                                                        try SourceHTTP.$testSession.withValue(session) {
                                                                            try operation()
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
