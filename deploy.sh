#!/bin/bash

set -e

echo "=== Switching to primary cluster ==="
kubectl config use-context production-cluster

echo "=== Applying PRIMARY resources ==="
kubectl apply -f primary-configmap.yaml -n primary
kubectl apply -f secret.yaml -n primary
kubectl apply -f primary.yaml -n primary

echo "=== Checking PRIMARY pods ==="
kubectl get pods -n primary
kubectl get svc -n primary

echo "==================================="

echo "=== Switching to secondary cluster ==="
kubectl config use-context secondary-cluster

echo "=== Applying SECONDARY resources ==="
kubectl apply -f secondary-configmap.yaml -n secondary
kubectl apply -f secret.yaml -n secondary
kubectl apply -f secondary.yaml -n secondary

echo "=== Checking SECONDARY pods ==="
kubectl get pods -n secondary
kubectl get svc -n secondary

echo "Done."