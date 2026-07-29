#ifndef __CHATAFL_RUNTIME_CONFIG_H
#define __CHATAFL_RUNTIME_CONFIG_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline const char *chatafl_runtime_value(
    const char *environment_name,
    const char *compiled_default)
{
    const char *configured_value = getenv(environment_name);

    if (configured_value != NULL && configured_value[0] != '\0')
        return configured_value;

    return compiled_default;
}

static inline const char *chatafl_runtime_model(const char *compiled_default)
{
    return chatafl_runtime_value("CHATAFL_MODEL", compiled_default);
}

static inline const char *chatafl_runtime_url(const char *compiled_default)
{
    return chatafl_runtime_value("CHATAFL_URL", compiled_default);
}

static inline char *chatafl_copy_secret(const char *value)
{
    size_t length = strlen(value);
    char *copy = malloc(length + 1);

    if (copy == NULL)
        return NULL;

    memcpy(copy, value, length + 1);
    return copy;
}

static inline char *chatafl_read_secret_file(const char *path)
{
    FILE *stream = fopen(path, "rb");
    long file_size;
    size_t length;
    char *secret;

    if (stream == NULL)
        return NULL;
    if (fseek(stream, 0, SEEK_END) != 0)
    {
        fclose(stream);
        return NULL;
    }
    file_size = ftell(stream);
    if (file_size <= 0 || file_size > 65536 || fseek(stream, 0, SEEK_SET) != 0)
    {
        fclose(stream);
        return NULL;
    }

    secret = malloc((size_t)file_size + 1);
    if (secret == NULL)
    {
        fclose(stream);
        return NULL;
    }
    length = fread(secret, 1, (size_t)file_size, stream);
    if (length != (size_t)file_size || ferror(stream))
    {
        free(secret);
        fclose(stream);
        return NULL;
    }
    fclose(stream);

    while (length > 0
           && (secret[length - 1] == '\n' || secret[length - 1] == '\r'))
        length--;
    if (length == 0)
    {
        free(secret);
        return NULL;
    }
    secret[length] = '\0';
    return secret;
}

static inline char *chatafl_runtime_api_key(const char *compiled_default)
{
    const char *secret_file = getenv("CHATAFL_API_KEY_FILE");
    const char *environment_secret;

    if (secret_file != NULL && secret_file[0] != '\0')
        return chatafl_read_secret_file(secret_file);

    environment_secret = getenv("CHATAFL_API_KEY");
    if (environment_secret != NULL && environment_secret[0] != '\0')
        return chatafl_copy_secret(environment_secret);

    return chatafl_copy_secret(compiled_default);
}

#endif /* __CHATAFL_RUNTIME_CONFIG_H */
