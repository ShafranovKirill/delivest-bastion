defmodule Bastion.Domains.Secrets do
  @moduledoc "Encrypts REG.RU credentials with a persistent, separately configured key."

  def encrypt(secret) when is_binary(secret) do
    with {:ok, key} <- key() do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, secret, "delivest-dns-v1", true)

      {:ok, <<1, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  def decrypt(<<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    with {:ok, key} <- key(),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             "delivest-dns-v1",
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  def decrypt(_), do: {:error, :credential_unavailable}

  defp key do
    case Application.get_env(:bastion, :dns_encryption_key) do
      encoded when is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          _ -> {:error, :encryption_key_invalid}
        end

      _ ->
        {:error, :encryption_key_missing}
    end
  end
end
