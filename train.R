# Load Package
library(keras)
library(progress)
library(abind)
k_set_image_data_format('channels_first')

source("build.R")

# Set Hyperparameter
epochs <- 50
batch_size <- 250
latent_size <- 100

adam_lr <- 0.0001 
adam_beta_1 <- 0.99

discriminator <- build_discriminator()
discriminator %>% compile(
  optimizer = optimizer_adam(lr = adam_lr, beta_1 = adam_beta_1),
  loss = list("binary_crossentropy", "sparse_categorical_crossentropy")
)


generator <- build_generator(latent_size)
generator %>% compile(
  optimizer = optimizer_adam(lr = adam_lr, beta_1 = adam_beta_1),
  loss = "binary_crossentropy"
)

latent <- layer_input(shape = list(latent_size))
image_class <- layer_input(shape = list(1), dtype = "int32")

fake <- generator(list(latent, image_class))

# Only want to be able to train generation for the combined model
freeze_weights(discriminator)
results <- discriminator(fake)

combined <- keras_model(list(latent, image_class), results)
combined %>% compile(
  optimizer = optimizer_adam(lr = adam_lr, beta_1 = adam_beta_1),
  loss = list("binary_crossentropy", "sparse_categorical_crossentropy")
)

source("data.R")

for(epoch in 1:epochs){
  
  num_batches <- trunc(num_train/batch_size)
  pb <- progress_bar$new(
    total = num_batches, 
    format = sprintf("epoch %s/%s, :elapsed [:bar] :percent :eta", epoch, epochs),
    clear = FALSE
  )
  
  epoch_gen_loss <- NULL
  epoch_disc_loss <- NULL
  
  possible_indexes <- 1:num_train
  
  for(index in 1:num_batches){
    
    pb$tick()
    
    # Generate a new batch of noise
    noise <- runif(n = batch_size*latent_size, min = -1, max = 1) %>%
      matrix(nrow = batch_size, ncol = latent_size)
    
    # Get a batch of real images
    batch <- sample(possible_indexes, size = batch_size)
    possible_indexes <- possible_indexes[!possible_indexes %in% batch]
    image_batch <- mnist$train$x[batch,,,,drop = FALSE]
    label_batch <- mnist$train$y[batch]
    
    # Sample some labels from p_c
    sampled_labels <- sample(0:9, batch_size, replace = TRUE) %>%
      matrix(ncol = 1)
    
    # Generate a batch of fake images, using the generated labels as a
    # conditioner. We reshape the sampled labels to be
    # (batch_size, 1) so that we can feed them into the embedding
    # layer as a length one sequence
    generated_images <- predict(generator, list(noise, sampled_labels))
    
    X <- abind(image_batch, generated_images, along = 1)
    y <- c(rep(1L, batch_size), rep(0L, batch_size)) %>% matrix(ncol = 1)
    aux_y <- c(label_batch, sampled_labels) %>% matrix(ncol = 1)
    
    # Check if the discriminator can figure itself out
    disc_loss <- train_on_batch(
      discriminator, x = X, 
      y = list(y, aux_y)
    )
    
    epoch_disc_loss <- rbind(epoch_disc_loss, unlist(disc_loss))
    
    # Make new noise. Generate 2 * batch size here such that
    # the generator optimizes over an identical number of images as the
    # discriminator
    noise <- runif(2*batch_size*latent_size, min = -1, max = 1) %>%
      matrix(nrow = 2*batch_size, ncol = latent_size)
    sampled_labels <- sample(0:9, size = 2*batch_size, replace = TRUE) %>%
      matrix(ncol = 1)
    
    # Want to train the generator to trick the discriminator
    # For the generator, we want all the {fake, not-fake} labels to say
    # not-fake
    trick <- rep(1, 2*batch_size) %>% matrix(ncol = 1)
    
    combined_loss <- train_on_batch(
      combined, 
      list(noise, sampled_labels),
      list(trick, sampled_labels)
    )
    
    epoch_gen_loss <- rbind(epoch_gen_loss, unlist(combined_loss))
    
  }
  
  cat(sprintf("\nTesting for epoch %02d:", epoch))
  
  # Evaluate the testing loss here
  
  # Generate a new batch of noise
  noise <- runif(num_test*latent_size, min = -1, max = 1) %>%
    matrix(nrow = num_test, ncol = latent_size)
  
  # Sample some labels from p_c and generate images from them
  sampled_labels <- sample(0:9, size = num_test, replace = TRUE) %>%
    matrix(ncol = 1)
  generated_images <- predict(generator, list(noise, sampled_labels))
  
  X <- abind(mnist$test$x, generated_images, along = 1)
  y <- c(rep(1, num_test), rep(0, num_test)) %>% matrix(ncol = 1)
  aux_y <- c(mnist$test$y, sampled_labels) %>% matrix(ncol = 1)
  
  # See if the discriminator can figure itself out...
  discriminator_test_loss <- evaluate(
    discriminator, X, list(y, aux_y), 
    verbose = FALSE
  ) %>% unlist()
  
  discriminator_train_loss <- apply(epoch_disc_loss, 2, mean)
  
  # Make new noise
  noise <- runif(2*num_test*latent_size, min = -1, max = 1) %>%
    matrix(nrow = 2*num_test, ncol = latent_size)
  sampled_labels <- sample(0:9, size = 2*num_test, replace = TRUE) %>%
    matrix(ncol = 1)
  
  trick <- rep(1, 2*num_test) %>% matrix(ncol = 1)
  
  generator_test_loss = combined %>% evaluate(
    list(noise, sampled_labels),
    list(trick, sampled_labels),
    verbose = FALSE
  )
  
  generator_train_loss <- apply(epoch_gen_loss, 2, mean)
  
  
  # Generate an epoch report on performance
  row_fmt <- "\n%22s : loss %4.2f | %5.2f | %5.2f"
  cat(sprintf(
    row_fmt, 
    "generator (train)",
    generator_train_loss[1],
    generator_train_loss[2],
    generator_train_loss[3]
  ))
  cat(sprintf(
    row_fmt, 
    "generator (test)",
    generator_test_loss[1],
    generator_test_loss[2],
    generator_test_loss[3]
  ))
  
  cat(sprintf(
    row_fmt, 
    "discriminator (train)",
    discriminator_train_loss[1],
    discriminator_train_loss[2],
    discriminator_train_loss[3]
  ))
  
  cat(sprintf(
    row_fmt, 
    "discriminator (test)",
    discriminator_test_loss[1],
    discriminator_test_loss[2],
    discriminator_test_loss[3]
  ))
  
  cat("\n")
  
  # Generate some digits to display
  noise <- runif(10*latent_size, min = -1, max = 1) %>%
    matrix(nrow = 10, ncol = latent_size)
  
  sampled_labels <- 0:9 %>%
    matrix(ncol = 1)
  
  # Get a batch to display
  generated_images <- predict(
    generator,    
    list(noise, sampled_labels)
  )
  
  img <- NULL
  for(i in 1:10){
    img <- cbind(img, generated_images[i,,,])
  }
  
  ((img + 1)/2) %>% as.raster() %>%
    plot()
  
}