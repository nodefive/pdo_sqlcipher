dnl $Id$
dnl config.m4 for extension pdo_sqlcipher
dnl vim:et:sw=2:ts=2:

PHP_ARG_ENABLE(pdo_sqlcipher, whether to enable pdo_sqlcipher support,
[  --enable-pdo_sqlcipher  Enable pdo_sqlcipher support])

if test "$PHP_PDO_SQLCIPHER" != "no"; then

    if test "$PHP_PDO" = "no" && test "$ext_shared" = "no"; then
        AC_MSG_ERROR([PDO is not enabled! Add --enable-pdo to your configure line.])
    fi

    AC_MSG_CHECKING([for PDO includes])
    if test -f $abs_srcdir/include/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$abs_srcdir/ext
    elif test -f $abs_srcdir/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$abs_srcdir/ext
    elif test -f $phpincludedir/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$phpincludedir/ext
    elif test -f $prefix/include/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/ext
    elif test -f $prefix/include/php5/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php5/ext
    dnl PHP 5.x specific paths
    elif test -f $prefix/include/php/5.5/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/5.5/php/ext
    elif test -f $prefix/include/php/5.6/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/5.6/php/ext
    dnl PHP 7.0-7.4 paths
    elif test -f $prefix/include/php/7.0/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/7.0/php/ext
    elif test -f $prefix/include/php/7.1/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/7.1/php/ext
    elif test -f $prefix/include/php/7.2/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/7.2/php/ext
    elif test -f $prefix/include/php/7.3/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/7.3/php/ext
    elif test -f $prefix/include/php/7.4/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/7.4/php/ext
    dnl PHP 8.0-8.3 paths
    elif test -f $prefix/include/php/8.0/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/8.0/php/ext
    elif test -f $prefix/include/php/8.1/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/8.1/php/ext
    elif test -f $prefix/include/php/8.2/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/8.2/php/ext
    elif test -f $prefix/include/php/8.3/php/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/8.3/php/ext
    dnl Alternative paths with version in directory name
    elif test -f $prefix/include/php7/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php7/ext
    elif test -f $prefix/include/php8/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php8/ext
    dnl Ubuntu/Debian specific paths for PHP 7.x
    elif test -f $prefix/include/php/20151012/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20151012/ext
    elif test -f $prefix/include/php/20160303/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20160303/ext
    elif test -f $prefix/include/php/20170718/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20170718/ext
    elif test -f $prefix/include/php/20180731/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20180731/ext
    elif test -f $prefix/include/php/20190902/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20190902/ext
    dnl Ubuntu/Debian specific paths for PHP 8.x
    elif test -f $prefix/include/php/20200930/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20200930/ext
    elif test -f $prefix/include/php/20210902/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20210902/ext
    elif test -f $prefix/include/php/20220829/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20220829/ext
    elif test -f $prefix/include/php/20230831/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20230831/ext
    dnl PHP 8.4 path
    elif test -f $prefix/include/php/20240924/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20240924/ext
    dnl PHP 8.5 path
    elif test -f $prefix/include/php/20250925/ext/pdo/php_pdo_driver.h; then
        pdo_inc_path=$prefix/include/php/20250925/ext
    dnl Try to find PHP API versions automatically
    else
        for apidir in $(find $prefix -name php_pdo_driver.h 2>/dev/null | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null | sort -u); do
            if test -f "$apidir/ext/pdo/php_pdo_driver.h"; then
                pdo_inc_path="$apidir/ext"
                break
            fi
        done
        
        if test "x$pdo_inc_path" = "x"; then
            AC_MSG_ERROR([Cannot find php_pdo_driver.h.])
        fi
    fi
    AC_MSG_RESULT($pdo_inc_path)

    php_pdo_sqlcipher_sources_core="pdo_sqlcipher.c sqlcipher_driver.c sqlcipher_statement.c sqlcipher3.c"

    if test -f "$srcdir/sqlcipher_sql_parser.c"; then
        php_pdo_sqlcipher_sources_core="$php_pdo_sqlcipher_sources_core sqlcipher_sql_parser.c"
    fi

    PHP_ADD_LIBRARY(crypto,, PDO_SQLCIPHER_SHARED_LIBADD)
    PHP_ADD_LIBRARY(icuuc,, PDO_SQLCIPHER_SHARED_LIBADD)
    PHP_ADD_LIBRARY(icui18n,, PDO_SQLCIPHER_SHARED_LIBADD)
    PHP_SUBST(PDO_SQLCIPHER_SHARED_LIBADD)

    PHP_NEW_EXTENSION(pdo_sqlcipher, $php_pdo_sqlcipher_sources_core, $ext_shared,,-I$pdo_inc_path)

    ifdef([PHP_ADD_EXTENSION_DEP],
    [
        PHP_ADD_EXTENSION_DEP(pdo_sqlcipher, pdo)
    ])
fi
