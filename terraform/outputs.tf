output "image_id" {
  description = "Imported custom image OCID"
  value       = oci_core_image.nixos.id
}

output "instance_ip" {
  description = "Public IPv4 of the launched instance"
  value       = oci_core_instance.nixos.public_ip
}

output "uploaded_object" {
  description = "Object Storage path (namespace/bucket/object)"
  value       = "${var.namespace}/${oci_objectstorage_bucket.nixos_bucket.name}/${oci_objectstorage_object.nixos_image.object}"
}
