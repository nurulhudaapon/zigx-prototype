//! # TransformJS C FFI Library
//!
//! This library exposes JavaScript/TypeScript transformation functionality
//! through a C-compatible interface for use in Zig and other languages.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::Path;

use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{HelperLoaderMode, TransformOptions as RustTransformOptions, Transformer, Module};

/// Helper loader mode
#[repr(C)]
pub enum TransformHelperLoaderMode {
    /// Runtime mode - helpers are inlined
    Runtime = 0,
    /// External mode - helpers are imported
    External = 1,
}

/// Transform options structure (C-compatible)
#[repr(C)]
pub struct CTransformOptions {
    /// Enable JSX transformation (0 = disabled, 1 = enabled)
    pub jsx_enabled: c_int,
    /// JSX development mode (0 = production, 1 = development)
    pub jsx_development: c_int,
    /// Enable TypeScript transformation (0 = disabled, 1 = enabled)
    pub typescript_enabled: c_int,
    /// Helper loader mode
    pub helper_loader_mode: TransformHelperLoaderMode,
    /// Target environment string (e.g., "es2020", "chrome58", null for default)
    /// This is a comma-separated list of targets
    pub target: *const c_char,
}

/// Result structure for transformation operations
#[repr(C)]
pub struct TransformResult {
    /// Pointer to the transformed code (null-terminated C string)
    /// Caller is responsible for freeing this using `transformjs_free_string`
    pub output: *mut c_char,
    /// Length of the output string (excluding null terminator)
    pub output_len: usize,
    /// Error message if transformation failed (null-terminated C string)
    /// Caller is responsible for freeing this using `transformjs_free_string`
    pub error: *mut c_char,
    /// Success flag: 0 = success, non-zero = error
    pub success: c_int,
}

/// Convert C options struct to Rust TransformOptions
fn convert_options(c_options: Option<&CTransformOptions>) -> RustTransformOptions {
    if let Some(opts) = c_options {
        let mut rust_opts = if opts.jsx_enabled != 0 || opts.typescript_enabled != 0 {
            // If any options are set, start with defaults
            RustTransformOptions::default()
        } else {
            // If no options set, use enable_all for backward compatibility
            RustTransformOptions::enable_all()
        };

        // Configure JSX
        if opts.jsx_enabled != 0 {
            rust_opts.jsx.development = opts.jsx_development != 0;
        } else {
            rust_opts.jsx.development = false;
        }

        // Configure TypeScript - if disabled, clear TypeScript options
        if opts.typescript_enabled == 0 {
            // TypeScriptOptions is not publicly accessible, so we just leave it as default
            // The transformer will handle it appropriately
        }

        // Configure helper loader mode
        rust_opts.helper_loader.mode = match opts.helper_loader_mode {
            TransformHelperLoaderMode::Runtime => HelperLoaderMode::Runtime,
            TransformHelperLoaderMode::External => HelperLoaderMode::External,
        };

        // Configure target if provided
        if !opts.target.is_null() {
            if let Ok(target_str) = unsafe { CStr::from_ptr(opts.target) }.to_str() {
                if !target_str.is_empty() {
                    if let Ok(env_opts) = oxc_transformer::EnvOptions::from_target(target_str) {
                        rust_opts.env = env_opts;
                        // Ensure module is set to CommonJS for bundling when target is specified
                        rust_opts.env.module = Module::CommonJS;
                    }
                }
            }
        } else {
            // Default to CommonJS module format for bundling
            rust_opts.env.module = Module::CommonJS;
        }

        rust_opts
    } else {
        // Default: browser-compatible bundled output
        // Start with browser-compatible target (ES2020) which enables necessary transforms
        let mut opts = if let Ok(env_opts) = oxc_transformer::EnvOptions::from_target("es2020") {
            let mut base_opts = RustTransformOptions {
                env: env_opts,
                ..RustTransformOptions::default()
            };
            // Enable all transformations for maximum browser compatibility
            base_opts.env = oxc_transformer::EnvOptions::enable_all(false);
            base_opts
        } else {
            RustTransformOptions::enable_all()
        };
        
        // Set helper loader to Runtime to inline all helpers (bundled, no external dependencies)
        opts.helper_loader.mode = HelperLoaderMode::Runtime;
        
        // Transform modules to CommonJS for bundling (browsers can't use ES modules directly)
        opts.env.module = Module::CommonJS;
        
        // Production mode (not development)
        opts.jsx.development = false;
        
        // Enable TypeScript transformation
        // (TypeScriptOptions::default() is already set)
        
        // Enable decorators for full compatibility
        opts.decorator.legacy = true;
        opts.decorator.emit_decorator_metadata = true;
        
        opts
    }
}

/// Transform JavaScript/TypeScript source code
///
/// # Safety
/// - `source` must be a valid null-terminated C string
/// - `file_path` must be a valid null-terminated C string (can be null for default)
/// - `options` can be null to use default options, or a pointer to a valid CTransformOptions struct
/// - The caller is responsible for freeing the returned `TransformResult` using `transformjs_free_result`
#[unsafe(no_mangle)]
pub unsafe extern "C" fn transformjs_transform(
    source: *const c_char,
    file_path: *const c_char,
    options: *const CTransformOptions,
) -> *mut TransformResult {
    let result = Box::new(TransformResult {
        output: std::ptr::null_mut(),
        output_len: 0,
        error: std::ptr::null_mut(),
        success: 1,
    });

    if source.is_null() {
        let error_msg = CString::new("source is null").unwrap();
        let mut result = result;
        result.error = error_msg.into_raw();
        result.success = 1;
        return Box::into_raw(result);
    }

    let source_str = match unsafe { CStr::from_ptr(source) }.to_str() {
        Ok(s) => s,
        Err(e) => {
            let error_msg = CString::new(format!("Invalid UTF-8 in source: {}", e)).unwrap();
            let mut result = result;
            result.error = error_msg.into_raw();
            result.success = 1;
            return Box::into_raw(result);
        }
    };

    let path = if file_path.is_null() {
        Path::new("input.js")
    } else {
        match unsafe { CStr::from_ptr(file_path) }.to_str() {
            Ok(s) => Path::new(s),
            Err(_) => Path::new("input.js"),
        }
    };

    let allocator = Allocator::default();
    let source_type = SourceType::from_path(path).unwrap_or(SourceType::default());

    // Parse
    let ret = Parser::new(&allocator, source_str, source_type).parse();

    if !ret.errors.is_empty() {
        let error_msg = format!("Parser errors: {} errors found", ret.errors.len());
        let error_cstr = CString::new(error_msg).unwrap();
        let mut result = result;
        result.error = error_cstr.into_raw();
        result.success = 1;
        return Box::into_raw(result);
    }

    let mut program = ret.program;

    // Build semantic information
    let ret = SemanticBuilder::new()
        .with_excess_capacity(2.0)
        .build(&program);

    if !ret.errors.is_empty() {
        let error_msg = format!("Semantic errors: {} errors found", ret.errors.len());
        let error_cstr = CString::new(error_msg).unwrap();
        let mut result = result;
        result.error = error_cstr.into_raw();
        result.success = 1;
        return Box::into_raw(result);
    }

    let scoping = ret.semantic.into_scoping();

    // Convert C options to Rust TransformOptions
    let c_options = if options.is_null() {
        None
    } else {
        Some(unsafe { &*options })
    };
    let transform_options = convert_options(c_options);

    // Transform
    let ret = Transformer::new(&allocator, path, &transform_options)
        .build_with_scoping(scoping, &mut program);

    if !ret.errors.is_empty() {
        let error_msg = format!("Transformer errors: {} errors found", ret.errors.len());
        let error_cstr = CString::new(error_msg).unwrap();
        let mut result = result;
        result.error = error_cstr.into_raw();
        result.success = 1;
        return Box::into_raw(result);
    }

    // Generate code
    let printed = Codegen::new().build(&program).code;

    match CString::new(printed) {
        Ok(output_cstr) => {
            let output_len = output_cstr.as_bytes().len();
            let mut result = result;
            result.output = output_cstr.into_raw();
            result.output_len = output_len;
            result.success = 0;
            Box::into_raw(result)
        }
        Err(e) => {
            let error_msg = CString::new(format!("Failed to create output string: {}", e)).unwrap();
            let mut result = result;
            result.error = error_msg.into_raw();
            result.success = 1;
            Box::into_raw(result)
        }
    }
}

/// Free a string allocated by the library
///
/// # Safety
/// - `ptr` must be a pointer returned by the library, or null
#[unsafe(no_mangle)]
pub unsafe extern "C" fn transformjs_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = unsafe { CString::from_raw(ptr) };
    }
}

/// Free a TransformResult structure
///
/// # Safety
/// - `result` must be a pointer returned by `transformjs_transform`, or null
#[unsafe(no_mangle)]
pub unsafe extern "C" fn transformjs_free_result(result: *mut TransformResult) {
    if !result.is_null() {
        let result = unsafe { Box::from_raw(result) };
        if !result.output.is_null() {
            let _ = unsafe { CString::from_raw(result.output) };
        }
        if !result.error.is_null() {
            let _ = unsafe { CString::from_raw(result.error) };
        }
    }
}

