defmodule Bastion.Credentials do
  @moduledoc "Encryption at rest using a purpose-specific key derived from SECRET_KEY_BASE."

  def encrypt(password) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, password, "admin-password", true)

    Base.encode64(nonce <> tag <> ciphertext)
  end

  def decrypt(nil), do: {:ok, nil}

  def decrypt(encoded) do
    with {:ok, <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.decode64(encoded),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key(),
             nonce,
             ciphertext,
             "admin-password",
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid_key}
    end
  end

  def safe_link?(value) do
    uri = URI.parse(value)

    uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and
      not String.match?(value, ~r/[\s\x00-\x1f\x7f]/u)
  end

  defp key do
    :crypto.hash(
      :sha256,
      "bastion:admin-password:v1:" <> BastionWeb.Endpoint.config(:secret_key_base)
    )
  end
end
